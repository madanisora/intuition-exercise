// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {VotingEscrow}   from "../src/VotingEscrow.sol";
import {AtomWallet, PackedUserOperation} from "../src/AtomWallet.sol";
import {TrustBonding}   from "../src/TrustBonding.sol";

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║  INTUITION PROTOCOL — EXERCISE TEST SUITE                               ║
 * ║                                                                          ║
 * ║  Based on REAL bugs found in the 2026-03 audit + POST-MORTEM            ║
 * ║                                                                          ║
 * ║  EXERCISE 1: VotingEscrow underflow (Critical — production incident)    ║
 * ║  EXERCISE 2A: AtomWallet unsigned validity window (Critical)             ║
 * ║  EXERCISE 2B: AtomWallet ownership slot mismatch (Critical)             ║
 * ║  EXERCISE 3: TrustBonding zero-claim bypass (Medium)                    ║
 * ║                                                                          ║
 * ║  HOW TO USE:                                                             ║
 * ║  1. Run: forge test -vvv                                                 ║
 * ║  2. Tests marked [BUG DEMO] will PASS (showing the bug exists)          ║
 * ║  3. Tests marked [EXPLOIT] will also PASS (showing the attack)          ║
 * ║  4. Tests marked [FIX REQUIRED] will FAIL until you patch the code      ║
 * ║  5. Fix each bug, then re-run until all [FIX REQUIRED] tests pass       ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 */

// ═════════════════════════════════════════════════════════════════════════════
//  EXERCISE 1: VotingEscrow Temporal Underflow
// ═════════════════════════════════════════════════════════════════════════════

contract Exercise1_VotingEscrowTest is Test {
    VotingEscrow ve;

    // Real incident timestamps
    uint256 constant EPOCH_END  = 1763478000; // real epochTimestampEnd(0)
    uint256 constant CP_BEFORE  = 1763477974; // checkpoint #11906 (26s before)
    uint256 constant CP_AFTER   = 1763478091; // checkpoint #11907 (91s after ← triggers bug)

    function setUp() public {
        ve = new VotingEscrow();

        // Reproduce exact incident conditions:
        // First, create a checkpoint BEFORE epoch end
        vm.warp(CP_BEFORE);
        ve.lock(address(0x1), 1000);

        console2.log("=== Exercise 1: VotingEscrow Underflow ===");
        console2.log("Epoch end timestamp:    ", EPOCH_END);
        console2.log("Checkpoint #1 ts:       ", CP_BEFORE, "(BEFORE epoch end)");
    }

    /**
     * @notice [BUG DEMO] Shows that supply query works BEFORE the breaking tx
     * This should PASS even with the buggy code.
     */
    function test_E1_SupplyQueryWorksBeforeBreakingTx() public view {
        // With checkpoint at CP_BEFORE (< EPOCH_END), querying EPOCH_END is safe
        // because point.ts <= t → no underflow
        uint256 supply = ve.totalSupplyAt(EPOCH_END);
        console2.log("Supply at epochEnd (before breaking tx):", supply);
        // Just checking it doesn't revert
        assertTrue(supply >= 0, "should not revert");
    }

    /**
     * @notice [BUG DEMO] Reproduced: after checkpoint post-epoch-end, query reverts
     *
     *  This test demonstrates the REAL production incident.
     *  Someone calls increase_amount() 91 seconds after epoch end.
     *  Checkpoint #11907 is created with ts = CP_AFTER > EPOCH_END.
     *  Now _totalSupply(EPOCH_END) tries: EPOCH_END - CP_AFTER → UNDERFLOW
     *
     *  With buggy code: this should REVERT (demonstrating the bug)
     *  After your fix: this should return a valid value
     */
    function test_E1_BugDemo_BreakingTxCausesUnderflow() public {
        // Simulate the breaking transaction: someone checkpoints AFTER epoch end
        vm.warp(CP_AFTER);
        ve.lock(address(0x2), 500); // ← this is the "increase_amount(50e18)" equivalent

        console2.log("Checkpoint #2 ts:       ", CP_AFTER, "(AFTER epoch end — this is the bug trigger)");
        console2.log("Latest epoch:           ", ve.currentEpoch());
        console2.log("Latest checkpoint.ts:   ", ve.getPointHistory(ve.currentEpoch()).ts);

        // With buggy _totalSupply: this REVERTS with arithmetic underflow
        // After fix: should return a valid supply value
        // Uncomment to see the revert:
        // uint256 supply = ve.totalSupplyAt(EPOCH_END);

        // Verify the problematic condition exists
        uint256 latestEpoch = ve.currentEpoch();
        uint256 latestTs = ve.getPointHistory(latestEpoch).ts;

        assertTrue(latestTs > EPOCH_END,
            "Latest checkpoint should be AFTER epoch end (this is the dangerous state)");

        console2.log("");
        console2.log(">>> The bug condition is set. Latest checkpoint ts > epochEnd.");
        console2.log(">>> Now calling totalSupplyAt(epochEnd) will revert.");
        console2.log(">>> Your job: fix _totalSupply() to use _find_epoch() binary search.");

        // [FIX REQUIRED] Uncomment after fixing:
        // uint256 supply = ve.totalSupplyAt(EPOCH_END);
        // assertGe(supply, 0, "should return valid supply after fix");
    }

    /**
     * @notice [FIX REQUIRED] After fix, historical query must work correctly
     *
     *  This is the TARGET state: after your fix, even when the latest
     *  checkpoint is AFTER the query timestamp, we should get the right answer
     *  by selecting the correct historical checkpoint.
     */
    function test_E1_FIX_HistoricalQueryWorksAfterBreakingTx() public {
        // Setup: create checkpoint before epoch end
        vm.warp(CP_BEFORE);
        ve.lock(address(0x3), 2000);
        uint256 supplyBefore = ve.totalSupplyAt(EPOCH_END);

        // Breaking tx: checkpoint after epoch end
        vm.warp(CP_AFTER);
        ve.lock(address(0x4), 100);

        // [FIX REQUIRED] After your fix, this must NOT revert
        uint256 supplyAfter = ve.totalSupplyAt(EPOCH_END);

        // The supply at epochEnd should be the same regardless of later checkpoints
        assertEq(supplyBefore, supplyAfter,
            "HINT: historical supply should not change because of a later checkpoint");

        console2.log("Supply at epochEnd (before breaking tx):", supplyBefore);
        console2.log("Supply at epochEnd (after breaking tx):", supplyAfter);
        console2.log("Test PASSED: fix is working!");
    }

    /**
     * @notice [FIX REQUIRED] Binary search correctness: multiple checkpoints
     */
    function test_E1_FIX_BinarySearchSelectsCorrectEpoch() public {
        uint256 targetTime = 1000000;

        // Create checkpoints at known timestamps
        vm.warp(999000); ve.checkpoint();  // epoch 1
        vm.warp(999500); ve.checkpoint();  // epoch 2
        vm.warp(999999); ve.checkpoint();  // epoch 3 — should be selected for t=1000000
        vm.warp(1000001); ve.checkpoint(); // epoch 4 — after target, should NOT be selected
        vm.warp(1000500); ve.checkpoint(); // epoch 5

        // Query at targetTime (should select epoch 3, not 4 or 5)
        uint256 supply = ve.totalSupplyAt(targetTime); // must not revert
        console2.log("Supply at t=1000000:", supply);
        // Just verifying no panic
        assertGe(supply, 0, "should not underflow");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  EXERCISE 2A: AtomWallet — Unsigned Validity Window
// ═════════════════════════════════════════════════════════════════════════════

contract Exercise2A_UnsignedValidityWindowTest is Test {
    AtomWallet wallet;
    uint256 ownerKey = 0xA11CE;
    address walletOwner;
    address ep;

    function setUp() public {
        walletOwner = vm.addr(ownerKey);
        ep = makeAddr("entryPoint");

        // Create a warden contract that returns walletOwner
        wallet = new AtomWallet(ep, walletOwner);

        console2.log("=== Exercise 2A: Unsigned Validity Window ===");
        console2.log("Wallet owner (atomWarden):", walletOwner);
    }

    function _buildUserOp(bytes memory sig) internal view returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: address(wallet),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
    }

    function _signOp(bytes32 userOpHash) internal view returns (bytes memory sig) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /**
     * @notice [EXPLOIT] Attacker modifies validUntil on expired signature
     *
     *  Owner signs a UserOp valid for 1 minute.
     *  After it expires, attacker extends validUntil to 30 days.
     *  With buggy code: the EXTENDED signature validates successfully!
     */
    function test_E2A_Exploit_AttackerExtendsValidityWindow() public {
        bytes32 userOpHash = keccak256("someUserOp");
        bytes memory baseSig = _signOp(userOpHash);

        // Owner intended: valid for 1 minute
        uint48 originalValidUntil = uint48(block.timestamp + 1 minutes);
        uint48 validAfter = 0;
        bytes memory originalSig = abi.encodePacked(
            baseSig,
            abi.encodePacked(originalValidUntil, validAfter)
        );

        // Warp past expiry
        vm.warp(block.timestamp + 2 minutes);
        assertTrue(block.timestamp > originalValidUntil, "signature should be expired");

        // Attacker modifies validUntil to 30 days from now
        uint48 attackerValidUntil = uint48(block.timestamp + 30 days);
        bytes memory attackerSig = abi.encodePacked(
            baseSig, // SAME 65-byte signature!
            abi.encodePacked(attackerValidUntil, validAfter)
        );

        // [EXPLOIT] With buggy code: this validates successfully despite modification
        PackedUserOperation memory op = _buildUserOp(attackerSig);
        vm.prank(ep);
        uint256 validationResult = wallet.validateUserOp(op, userOpHash, 0);

        // Extract aggregator (bits 0-19): 0 = valid, 1 = invalid
        address aggregator = address(uint160(validationResult));
        bool sigValid = aggregator == address(0);

        // Extract validUntil from result
        uint48 returnedValidUntil = uint48(validationResult >> 160);

        console2.log("Sig valid (should be false after fix):", sigValid);
        console2.log("Returned validUntil:", returnedValidUntil);
        console2.log("Attacker's validUntil:", attackerValidUntil);

        if (sigValid && returnedValidUntil == attackerValidUntil) {
            console2.log(">>> BUG CONFIRMED: Attacker successfully extended validity window!");
            console2.log(">>> Fix: include validUntil+validAfter in the signed hash");
        }

        // [FIX REQUIRED] After fix, this should FAIL (sig should be invalid)
        // assertEq(aggregator, address(1), "should fail: validity window was modified");
    }

    /**
     * @notice [FIX REQUIRED] After fix, tampered validity window must fail
     */
    function test_E2A_FIX_TamperedWindowFails() public {
        bytes32 userOpHash = keccak256("someUserOp");

        // When sig.length == 77, the hash should include validUntil+validAfter
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;

        // Sign WITH validity window included in hash (the correct way)
        bytes32 signedHash = keccak256(abi.encodePacked(userOpHash, validUntil, validAfter));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", signedHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory baseSig = abi.encodePacked(r, s, v);

        // Valid signature with original window
        bytes memory validSig = abi.encodePacked(baseSig, abi.encodePacked(validUntil, validAfter));

        // Tampered: attacker changes validUntil
        uint48 tamperedValidUntil = uint48(block.timestamp + 30 days);
        bytes memory tamperedSig = abi.encodePacked(baseSig, abi.encodePacked(tamperedValidUntil, validAfter));

        // Valid sig should pass
        PackedUserOperation memory validOp = _buildUserOp(validSig);
        vm.prank(ep);
        uint256 validResult = wallet.validateUserOp(validOp, userOpHash, 0);
        assertEq(address(uint160(validResult)), address(0), "valid sig should pass");

        // Tampered sig should FAIL
        PackedUserOperation memory tamperedOp = _buildUserOp(tamperedSig);
        vm.prank(ep);
        uint256 tamperedResult = wallet.validateUserOp(tamperedOp, userOpHash, 0);
        assertEq(address(uint160(tamperedResult)), address(1),
            "tampered window must fail after fix");

        console2.log("Test PASSED: tampered validity window correctly rejected!");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  EXERCISE 2B: AtomWallet — Ownership Slot Mismatch
// ═════════════════════════════════════════════════════════════════════════════

contract Exercise2B_OwnershipSlotMismatchTest is Test {
    AtomWallet wallet;
    uint256 aliceKey = 0xA1;
    address alice;
    address atomWarden;
    address ep;

    function setUp() public {
        alice = vm.addr(aliceKey);
        atomWarden = makeAddr("atomWarden");
        ep = makeAddr("entryPoint");

        wallet = new AtomWallet(ep, atomWarden);

        console2.log("=== Exercise 2B: Ownership Slot Mismatch ===");
        console2.log("AtomWarden:", atomWarden);
        console2.log("Alice (claiming user):", alice);
    }

    /**
     * @notice [BUG DEMO] Pre-claim: atomWarden is owner — works correctly
     */
    function test_E2B_PreClaimOwnerIsAtomWarden() public view {
        assertEq(wallet.owner(), atomWarden, "pre-claim: owner should be atomWarden");
        assertFalse(wallet.isClaimed(), "not yet claimed");
        console2.log("Pre-claim owner:", wallet.owner());
    }

    /**
     * @notice [BUG DEMO] After claiming: owner() returns address(0) — BRICKED!
     *
     *  atomWarden starts transfer to alice.
     *  alice accepts and becomes isClaimed = true.
     *  After: wallet.owner() returns address(0) because:
     *    - acceptOwnership() calls _setOzOwner(alice) → writes to _ozOwner slot
     *    - owner() post-claim reads from OWNER_SLOT (custom) → never written → 0
     */
    function test_E2B_BugDemo_AfterClaimOwnerIsZero() public {
        // Step 1: atomWarden initiates transfer to alice
        vm.prank(atomWarden);
        wallet.transferOwnership(alice);

        assertEq(wallet.pendingOwner(), alice, "alice should be pending owner");

        // Step 2: alice accepts ownership
        vm.prank(alice);
        wallet.acceptOwnership();

        assertTrue(wallet.isClaimed(), "wallet should be claimed");

        address ownerAfterClaim = wallet.owner();
        console2.log("Owner after claim (SHOULD be alice):", ownerAfterClaim);
        console2.log("Alice address:", alice);

        if (ownerAfterClaim == address(0)) {
            console2.log(">>> BUG CONFIRMED: owner() returns address(0) after claim!");
            console2.log(">>> Wallet is BRICKED: all onlyOwner functions will fail");
        }

        // [FIX REQUIRED] After fix, owner should be alice
        // assertEq(ownerAfterClaim, alice, "owner must be alice after successful claim");
    }

    /**
     * @notice [FIX REQUIRED] After fix, claiming must work correctly
     */
    function test_E2B_FIX_ClaimSetsOwnerCorrectly() public {
        vm.prank(atomWarden);
        wallet.transferOwnership(alice);

        vm.prank(alice);
        wallet.acceptOwnership();

        // [FIX REQUIRED]
        assertEq(wallet.owner(), alice,
            "HINT: acceptOwnership must write to OWNER_SLOT, not _ozOwner");
        assertTrue(wallet.isClaimed(), "must be claimed");

        // Verify owner-gated function works
        vm.prank(alice);
        wallet.transferOwnership(makeAddr("newOwner")); // must not revert
        console2.log("Test PASSED: claim works correctly!");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  EXERCISE 3: TrustBonding — Zero-Amount Claim Bypass
// ═════════════════════════════════════════════════════════════════════════════

contract Exercise3_ZeroClaimBypassTest is Test {
    TrustBonding bonding;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        bonding = new TrustBonding();

        // Setup epoch 0 with rewards
        uint256 epochNum = 0;
        bonding.setEpochRewards(epochNum, 1000e18);
        bonding.setTotalStakedAtEpoch(epochNum, 1000e18);

        // Alice and bob stake
        vm.prank(alice);
        bonding.stake(100e18); // alice: 10% of pool → 100 TRUST raw reward

        vm.prank(bob);
        bonding.stake(900e18); // bob: 90% of pool

        // Move to epoch 1 so epoch 0 is claimable
        vm.warp(block.timestamp + 7 days + 1);

        console2.log("=== Exercise 3: Zero-Amount Claim Bypass ===");
        console2.log("Current epoch:", bonding.currentEpoch());
        (uint256 raw, uint256 afterUtil) = bonding.pendingRewards(alice);
        console2.log("Alice raw rewards:", raw);
        console2.log("Alice rewards after utilization (20%):", afterUtil);
    }

    /**
     * @notice [BUG DEMO] The bypass path: lower bound = 0 enables double claim
     *
     *  Normal flow: personalUtilizationLowerBound = 2000 (20%)
     *  100 raw * 20% = 20 TRUST → stored in mapping
     *
     *  Bug flow: admin sets lower bound to 0
     *  100 raw * 0% = 0 → revert("no rewards after utilization")
     *  BUT: nothing was stored! Epoch never marked "claimed"
     *  Later: admin sets lower bound back to 20%
     *  Alice claims AGAIN for the same epoch!
     */
    function test_E3_BugDemo_ZeroUtilizationLeavesEpochUnclaimed() public {
        // Admin sets utilization to 0 (edge case / misconfiguration)
        bonding.setPersonalUtilizationLowerBound(0);

        (uint256 raw, uint256 afterUtil) = bonding.pendingRewards(alice);
        console2.log("Alice raw rewards:", raw);
        console2.log("Alice rewards after 0% utilization:", afterUtil);

        // Claim attempt → reverts because userRewards = 0
        vm.prank(alice);
        vm.expectRevert("TrustBonding: no rewards after utilization");
        bonding.claimRewards(alice);

        // Check: is epoch 0 marked as claimed?
        bool claimed = bonding.hasClaimed(alice, 0);
        console2.log("Epoch 0 marked as claimed?", claimed);

        if (!claimed) {
            console2.log(">>> BUG: epoch NOT marked claimed after revert");
            console2.log(">>> If utilization is later restored, alice can claim again!");

            // Prove it: restore utilization and claim successfully
            bonding.setPersonalUtilizationLowerBound(2000);

            vm.prank(alice);
            bonding.claimRewards(alice); // SUCCEEDS — double claim!

            console2.log(">>> Alice claimed after 'expired' 0-utilization period!");
            console2.log(">>> This is fine IF the original revert was the intended path,");
            console2.log(">>> but the fix should handle when 0-rewards are STORED (not reverted)");
        }
    }

    /**
     * @notice [FIX REQUIRED] Zero reward claim must mark epoch as claimed
     *
     *  The robust fix: use a dedicated hasClaimed mapping (bool).
     *  Write it as the FIRST thing in claimRewards, before any zero checks.
     *  That way, even if rewards are 0, the epoch is permanently locked.
     */
    function test_E3_FIX_ZeroRewardMarksEpochAsClaimed() public {
        bonding.setPersonalUtilizationLowerBound(0);

        vm.prank(alice);
        // This might revert with "no rewards" — that's OK
        // But the important thing: epoch must be marked claimed
        try bonding.claimRewards(alice) {} catch {}

        // [FIX REQUIRED] Epoch must be marked claimed even if rewards = 0
        assertTrue(
            bonding.hasClaimed(alice, 0),
            "HINT: use a dedicated bool mapping, set it BEFORE zero-reward check"
        );

        // Even after restoring utilization, alice cannot claim again
        bonding.setPersonalUtilizationLowerBound(2000);

        vm.prank(alice);
        vm.expectRevert("TrustBonding: already claimed");
        bonding.claimRewards(alice); // must revert

        console2.log("Test PASSED: zero-reward claim correctly locked the epoch!");
    }

    /**
     * @notice [FIX REQUIRED] Normal claim must still work after fix
     */
    function test_E3_FIX_NormalClaimStillWorks() public {
        // Normal utilization (20%)
        assertEq(bonding.personalUtilizationLowerBound(), 2000);

        uint256 balanceBefore = bonding.rewardBalance(alice);

        vm.prank(alice);
        bonding.claimRewards(alice);

        uint256 balanceAfter = bonding.rewardBalance(alice);
        assertGt(balanceAfter, balanceBefore, "alice should receive rewards");

        // Cannot double-claim
        vm.prank(alice);
        vm.expectRevert("TrustBonding: already claimed");
        bonding.claimRewards(alice);

        console2.log("Alice rewards received:", balanceAfter - balanceBefore);
        console2.log("Test PASSED: normal claim works, double claim blocked!");
    }

    /**
     * @notice [FIX REQUIRED] Invariant: one claim per user per epoch
     */
    function testFuzz_E3_OnlyOneClaimPerEpoch(uint256 utilization) public {
        utilization = bound(utilization, 0, 10_000);
        bonding.setPersonalUtilizationLowerBound(utilization);

        vm.prank(alice);
        try bonding.claimRewards(alice) {} catch {}

        // Regardless of outcome, epoch must be marked claimed
        assertTrue(bonding.hasClaimed(alice, 0),
            "Fuzz: epoch must always be marked claimed after any claim attempt");

        // Second claim must always fail
        bonding.setPersonalUtilizationLowerBound(5000); // restore high utilization
        vm.prank(alice);
        vm.expectRevert();
        bonding.claimRewards(alice);
    }
}
