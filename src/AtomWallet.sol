// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  EXERCISE 2: AtomWallet — Two Critical Bugs                     ║
 * ║                                                                  ║
 * ║  BUG A (Critical): Unsigned Validity Window Metadata            ║
 * ║  validUntil / validAfter are appended to signature but NOT      ║
 * ║  included in the signed hash. Any relayer can modify them.      ║
 * ║                                                                  ║
 * ║  BUG B (Critical): Ownership Slot Mismatch                      ║
 * ║  isClaimed flips which storage slot owner() reads from,         ║
 * ║  but acceptOwnership() writes to OZ default slot.               ║
 * ║  After claim: owner() returns address(0) → wallet bricked.     ║
 * ║                                                                  ║
 * ║  YOUR TASK:                                                      ║
 * ║  Bug A: Include validUntil+validAfter in the signed hash        ║
 * ║  Bug B: Ensure acceptOwnership writes to the SAME slot          ║
 * ║         that owner() reads from after isClaimed = true          ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */

// Minimal ERC-4337 interfaces (simplified for exercise)
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

library ECDSA {
    enum RecoverError { NoError, InvalidSignature, InvalidSignatureLength, InvalidSignatureS }

    function tryRecover(bytes32 hash, bytes memory signature)
        internal
        pure
        returns (address, RecoverError, bytes32)
    {
        if (signature.length != 65) {
            return (address(0), RecoverError.InvalidSignatureLength, bytes32(signature.length));
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }
        address recovered = ecrecover(hash, v, r, s);
        if (recovered == address(0)) {
            return (address(0), RecoverError.InvalidSignature, bytes32(0));
        }
        return (recovered, RecoverError.NoError, bytes32(0));
    }
}

/**
 * @title AtomWallet (Simplified, with bugs preserved for exercise)
 */
contract AtomWallet {
    // ─── Custom storage slots (EIP-1967 style) ────────────────────────────────
    bytes32 private constant OWNER_SLOT =
        keccak256("intuition.atomwallet.owner") - bytes32(uint256(1));

    bytes32 private constant PENDING_OWNER_SLOT =
        keccak256("intuition.atomwallet.pendingOwner") - bytes32(uint256(1));

    // ─── Inherited OZ Ownable2Step default slot (slot 0 in typical layout) ───
    // OZ stores owner at this slot in its default layout:
    address private _ozOwner;         // slot 0 → OZ default owner
    address private _ozPendingOwner;  // slot 1 → OZ default pendingOwner

    /// @notice Once claimed, owner() reads from OWNER_SLOT (custom)
    bool public isClaimed;

    address public immutable atomWarden;
    address public immutable entryPoint;

    // ─── Events ────────────────────────────────────────────────────────────────
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address _entryPoint, address _atomWarden) {
        entryPoint = _entryPoint;
        atomWarden = _atomWarden;
        // Initialize OZ slot (pre-claim phase)
        _ozOwner = _atomWarden;
    }

    // ─── Ownership ────────────────────────────────────────────────────────────

    /**
     * @notice Returns owner based on claim state
     * @dev Pre-claim: reads from OZ slot (_ozOwner = atomWarden)
     *      Post-claim: reads from CUSTOM slot (OWNER_SLOT)
     *
     * ⚠️  BUG B: acceptOwnership() calls _setOzOwner() which writes to _ozOwner,
     *     but post-claim, owner() reads from OWNER_SLOT → returns address(0)!
     */
    function owner() public view returns (address) {
        if (!isClaimed) {
            return _ozOwner; // pre-claim: atomWarden
        }
        // post-claim: read from custom slot
        address _owner;
        assembly {
            _owner := sload(OWNER_SLOT)
        }
        return _owner; // ← returns address(0) after bug B
    }

    function pendingOwner() public view returns (address) {
        // reads from custom slot
        address _pending;
        assembly {
            _pending := sload(PENDING_OWNER_SLOT)
        }
        return _pending;
    }

    /**
     * @notice Start ownership transfer — writes to CUSTOM slot
     */
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner(), "AtomWallet: not owner");
        require(newOwner != address(0), "AtomWallet: zero address");

        assembly {
            sstore(PENDING_OWNER_SLOT, newOwner)
        }
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * ╔════════════════════════════════════════════════════════════╗
     * ║  🐛 BUG B IS HERE                                        ║
     * ║                                                            ║
     * ║  pendingOwner() reads from CUSTOM slot (PENDING_OWNER_SLOT)║
     * ║  _setOzOwner() writes to OZ slot (_ozOwner)               ║
     * ║  owner() post-claim reads from CUSTOM slot (OWNER_SLOT)   ║
     * ║                                                            ║
     * ║  Result: OWNER_SLOT is never set → owner() = address(0)   ║
     * ║                                                            ║
     * ║  FIX: write to OWNER_SLOT instead of _ozOwner             ║
     * ╚════════════════════════════════════════════════════════════╝
     */
    function acceptOwnership() external {
        address sender = msg.sender;
        require(pendingOwner() == sender, "AtomWallet: not pending owner");

        if (!isClaimed) {
            isClaimed = true;
        }

        // ❌ BUG B: writes to OZ slot, but owner() post-claim reads OWNER_SLOT
        _setOzOwner(sender);

        // Clear pending owner
        assembly {
            sstore(PENDING_OWNER_SLOT, 0)
        }

        emit OwnershipTransferred(atomWarden, sender);
    }

    function _setOzOwner(address newOwner) internal {
        _ozOwner = newOwner; // writes OZ slot, NOT OWNER_SLOT
    }

    // ─── ERC-4337 Signature Validation ───────────────────────────────────────

    /**
     * ╔════════════════════════════════════════════════════════════╗
     * ║  🐛 BUG A IS HERE                                        ║
     * ║                                                            ║
     * ║  Signature = abi.encodePacked(r, s, v) [65 bytes]         ║
     * ║           OR abi.encodePacked(r, s, v, validUntil, validAfter) [77 bytes]║
     * ║                                                            ║
     * ║  validUntil and validAfter are EXTRACTED from signature    ║
     * ║  but NEVER included in the hash that is signed.            ║
     * ║                                                            ║
     * ║  A relayer can take a valid 65-byte sig and append ANY     ║
     * ║  validUntil/validAfter → still verifies correctly!         ║
     * ║                                                            ║
     * ║  FIX: when sig.length == 77, hash includes validUntil+validAfter ║
     * ╚════════════════════════════════════════════════════════════╝
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 /* missingAccountFunds */
    ) external view returns (uint256 validationData) {
        (uint48 validUntil, uint48 validAfter, bytes memory signature) =
            _extractValidityWindow(userOp.signature);

        // ❌ BUG A: hash does NOT include validUntil/validAfter
        // Anyone can change those values without invalidating the signature
        bytes32 hash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash)
        );

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);

        if (err != ECDSA.RecoverError.NoError) {
            return _packValidationData(true, validUntil, validAfter);
        }

        bool sigFailed = recovered != owner();
        return _packValidationData(sigFailed, validUntil, validAfter);
    }

    /**
     * @notice Extract validity window from signature
     * @dev Format: [r(32)][s(32)][v(1)] = 65 bytes (no window)
     *              [r(32)][s(32)][v(1)][validUntil(6)][validAfter(6)] = 77 bytes
     */
    function _extractValidityWindow(bytes calldata sig)
        internal
        pure
        returns (uint48 validUntil, uint48 validAfter, bytes memory rawSig)
    {
        if (sig.length == 77) {
            rawSig = sig[0:65];
            uint96 packed = uint96(bytes12(sig[65:77]));
            validUntil = uint48(packed >> 48);
            validAfter = uint48(packed);
        } else {
            rawSig = sig;
            validUntil = 0;   // 0 = no expiry
            validAfter = 0;
        }
    }

    /**
     * @notice Pack ERC-4337 validation data
     * @dev Format: [aggregator(20)][validUntil(6)][validAfter(6)]
     *              aggregator = address(0) = sig valid
     *              aggregator = address(1) = sig failed
     */
    function _packValidationData(
        bool sigFailed,
        uint48 validUntil,
        uint48 validAfter
    ) internal pure returns (uint256) {
        return (sigFailed ? 1 : 0)
            | (uint256(validUntil) << 160)
            | (uint256(validAfter) << (160 + 48));
    }

    // ─── Execute ──────────────────────────────────────────────────────────────

    function execute(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == entryPoint || msg.sender == owner(), "AtomWallet: unauthorized");
        (bool ok, bytes memory result) = target.call{value: value}(data);
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    receive() external payable {}
}
