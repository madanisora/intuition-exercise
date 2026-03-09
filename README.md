# intuition-exercise

> Foundry exercise berdasarkan **bug nyata** dari audit Intuition Protocol (Maret 2026)
> Source: `POST-MORTEM.md` + `code_423n4_2026_03_intuition_findings.md`

---

## Bug Summary (dari audit asli)

| # | Contract | Severity | Status | Deskripsi |
|---|----------|----------|--------|-----------|
| 1 | `VotingEscrow` | **Critical** | Fixed (PR #126) | Temporal underflow di `_totalSupply()` → semua claim rewards fail |
| 2A | `AtomWallet` | **Critical** | Fixed | `validUntil`/`validAfter` tidak dimasukkan ke hash yang ditandatangani |
| 2B | `AtomWallet` | **Critical** | Incomplete | Ownership slot mismatch setelah `acceptOwnership()` → wallet bricked |
| 3 | `TrustBonding` | **Medium** | Incomplete | Zero-amount claim tidak mark epoch sebagai "claimed" → double claim |

---

## Setup

```bash
forge install foundry-rs/forge-std --no-commit
forge test -vvv
```

---

## Exercise 1 — VotingEscrow: Temporal Underflow

### File: `src/VotingEscrow.sol`

### Apa yang terjadi (incident asli 2025-11-18):

```
Timeline:
  15:00:00  Epoch 0 berakhir     (epochEnd = 1763478000)
  15:00:42  User claim berhasil  (checkpoint #11906 ts = 1763477974 < epochEnd ✓)
  15:01:31  User lain deposit    (checkpoint #11907 ts = 1763478091 > epochEnd ✗)
  15:01:31+ SEMUA claimRewards() REVERT dengan Panic(0x11)
```

### Root cause:

```solidity
// _totalSupply() SELALU ambil checkpoint terbaru
function _totalSupply(uint256 t) internal view returns (uint256) {
    Point memory point = point_history[epoch]; // ← epoch = latest!
    return _supply_at(point, t);
}

// _supply_at() mengasumsikan point.ts <= t
// Tapi setelah bug: point.ts = 1763478091 > t = 1763478000
// Maka: t_i - last_point.ts = 1763478000 - 1763478091 → UNDERFLOW!
last_point.bias -= last_point.slope * int128(int256(t_i - last_point.ts));
//                                           ^^^^^^^^^^^^^^^^^^^^^^^^^^
//                                           uint256 underflow → Panic(0x11)
```

### Fix:

```solidity
function _totalSupply(uint256 t) internal view returns (uint256) {
    uint256 _epoch = epoch;
    if (_epoch == 0) return 0;
    if (t < point_history[0].ts) return 0;

    // ✓ Cari checkpoint terakhir dengan ts <= t
    uint256 target_epoch = _find_epoch(t); // binary search
    Point memory point = point_history[target_epoch];
    return _supply_at(point, t);
}
```

---

## Exercise 2A — AtomWallet: Unsigned Validity Window

### File: `src/AtomWallet.sol`

### Masalah:

Signature ERC-4337 bisa menyertakan validity window:
```
[r (32 bytes)] [s (32 bytes)] [v (1 byte)] [validUntil (6 bytes)] [validAfter (6 bytes)]
```

Tapi validUntil/validAfter **tidak dimasukkan ke hash yang ditandatangani**:

```solidity
// ❌ BUGGY: hash hanya atas userOpHash, bukan validUntil/validAfter
bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
```

### Attack:

```
1. User sign userOp dengan validUntil = now + 1 menit
2. Signature kedaluwarsa
3. Attacker ambil signature 65 byte yang sama
4. Attacker append validUntil = now + 30 hari
5. Signature masih valid karena hash tidak mencakup validity window!
```

### Fix:

```solidity
bytes32 signedHash = userOpHash;
if (userOp.signature.length == 77) {
    // Bind validity window ke hash
    signedHash = keccak256(abi.encodePacked(userOpHash, validUntil, validAfter));
}
bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", signedHash));
```

---

## Exercise 2B — AtomWallet: Ownership Slot Mismatch

### Masalah:

AtomWallet punya dua fase: pre-claim (owner = atomWarden) dan post-claim (owner = user).
Switch dilakukan oleh `isClaimed`. Tapi ada **mismatch storage slot**:

```
transferOwnership() → tulis ke CUSTOM slot (PENDING_OWNER_SLOT)
pendingOwner()      → baca dari CUSTOM slot              ✓
acceptOwnership()   → tulis ke _ozOwner (OZ default slot) ✗
owner() post-claim  → baca dari CUSTOM slot (OWNER_SLOT)  ← never written!
                   → returns address(0) → WALLET BRICKED!
```

### Fix:

```solidity
function acceptOwnership() public override {
    // ...
    if (!isClaimed) { isClaimed = true; }

    // ✓ Write ke OWNER_SLOT (yang dibaca owner() post-claim)
    assembly {
        sstore(OWNER_SLOT, sender)
        sstore(PENDING_OWNER_SLOT, 0)
    }
}
```

---

## Exercise 3 — TrustBonding: Zero-Claim Bypass

### File: `src/TrustBonding.sol`

### Masalah:

```solidity
// "has claimed" dideteksi dari amount > 0
function _hasClaimedRewardsForEpoch(address user, uint256 epoch) internal view returns (bool) {
    return userClaimedRewardsForEpoch[user][epoch] > 0; // ← BUG
}
```

Jika `personalUtilizationLowerBound = 0`, maka:
- `rawRewards = 100` (non-zero)
- `userRewards = 100 * 0 / 10000 = 0`
- Kode: revert("no rewards") TANPA menulis storage
- Epoch tidak pernah ditandai "claimed"
- Setelah utilization dipulihkan: user bisa claim lagi!

### Fix:

```solidity
// Tambah dedicated flag
mapping(address => mapping(uint256 => bool)) public hasClaimedEpoch;

function claimRewards(address recipient) external {
    uint256 prevEpoch = currentEpoch() - 1;

    // ✓ Mark sebagai claimed DULU, sebelum zero check
    require(!hasClaimedEpoch[msg.sender][prevEpoch], "already claimed");
    hasClaimedEpoch[msg.sender][prevEpoch] = true; // ← atomic claim flag

    // Baru hitung rewards
    uint256 rewards = _calcRewards(msg.sender, prevEpoch);
    if (rewards > 0) {
        rewardBalance[recipient] += rewards;
    }
}
```

---

## Cara Run Tests

```bash
# Semua test (beberapa akan FAIL — itu yang harus kamu fix)
forge test -vvv

# Test per exercise
forge test --match-contract Exercise1 -vvv
forge test --match-contract Exercise2A -vvv
forge test --match-contract Exercise2B -vvv
forge test --match-contract Exercise3 -vvv

# Fuzz test
forge test --match-test testFuzz -vvv --fuzz-runs 500
```

### Status awal (sebelum fix):

| Test | Expected status |
|------|----------------|
| `test_E1_SupplyQueryWorksBeforeBreakingTx` | ✅ PASS |
| `test_E1_BugDemo_BreakingTxCausesUnderflow` | ✅ PASS (demo bug) |
| `test_E1_FIX_HistoricalQueryWorksAfterBreakingTx` | ❌ FAIL → fix me |
| `test_E1_FIX_BinarySearchSelectsCorrectEpoch` | ❌ FAIL → fix me |
| `test_E2A_Exploit_AttackerExtendsValidityWindow` | ✅ PASS (demo exploit) |
| `test_E2A_FIX_TamperedWindowFails` | ❌ FAIL → fix me |
| `test_E2B_PreClaimOwnerIsAtomWarden` | ✅ PASS |
| `test_E2B_BugDemo_AfterClaimOwnerIsZero` | ✅ PASS (demo bug) |
| `test_E2B_FIX_ClaimSetsOwnerCorrectly` | ❌ FAIL → fix me |
| `test_E3_BugDemo_ZeroUtilizationLeavesEpochUnclaimed` | ✅ PASS (demo bug) |
| `test_E3_FIX_ZeroRewardMarksEpochAsClaimed` | ❌ FAIL → fix me |
| `test_E3_FIX_NormalClaimStillWorks` | ✅ PASS |
| `testFuzz_E3_OnlyOneClaimPerEpoch` | ❌ FAIL → fix me |
