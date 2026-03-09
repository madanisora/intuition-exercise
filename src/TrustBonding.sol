// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  EXERCISE 3: TrustBonding — Zero-Amount Claim Bypass            ║
 * ║                                                                  ║
 * ║  BUG SEVERITY: Medium                                            ║
 * ║                                                                  ║
 * ║  ROOT CAUSE:                                                     ║
 * ║  _hasClaimedRewardsForEpoch() checks userClaimedRewardsForEpoch  ║
 * ║  > 0, but if rewards round to zero and the protocol stores 0,   ║
 * ║  the check never marks it as "claimed".                          ║
 * ║                                                                  ║
 * ║  ATTACK:                                                         ║
 * ║  1. Call claimRewards() → personal utilization makes it 0 →    ║
 * ║     reverts with TrustBonding_NoRewardsToClaim                  ║
 * ║  Actually: current code PREVENTS zero storage (reverts first)   ║
 * ║  But: if lower bound = 0, a user gets a non-zero rawReward,     ║
 * ║  personalUtilization = 0 → userRewards = 0 → code stores 0    ║
 * ║  → _hasClaimedRewards returns false → double claim possible     ║
 * ║                                                                  ║
 * ║  YOUR TASK:                                                      ║
 * ║  1. Add a dedicated claim flag (bool) separate from amount      ║
 * ║  2. Fix _hasClaimedRewardsForEpoch to use the flag              ║
 * ║  3. Set flag BEFORE the zero-check (so 0-reward = still claimed)║
 * ╚══════════════════════════════════════════════════════════════════╝
 */
contract TrustBonding {
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant EPOCH_DURATION = 7 days;

    address public immutable rewardToken; // simplified: just tracks balances
    uint256 public deployedAt;

    // ─── Reward accounting ────────────────────────────────────────────────────

    /// @notice Total rewards minted per epoch
    mapping(uint256 => uint256) public epochRewards;

    /// @notice Total staked balance of a user (simplified: set directly)
    mapping(address => uint256) public stakedBalance;

    /// @notice Total staked across all users per epoch snapshot
    mapping(uint256 => uint256) public totalStakedAtEpoch;

    /// @notice How much a user claimed in a given epoch
    mapping(address => mapping(uint256 => uint256)) public userClaimedRewardsForEpoch;

    // Total claimed per epoch (for unclaimed calculation)
    mapping(uint256 => uint256) public totalClaimedRewardsForEpoch;

    // ─── Bug: personalUtilizationLowerBound can be set to 0 ──────────────────
    uint256 public personalUtilizationLowerBound = 2000; // 20% normally

    // Simplified reward balance for testing
    mapping(address => uint256) public rewardBalance;
    uint256 public totalRewardPool;

    // ─── Events ────────────────────────────────────────────────────────────────
    event RewardsClaimed(address indexed user, address indexed recipient, uint256 amount);
    event Staked(address indexed user, uint256 amount);

    constructor() {
        deployedAt = block.timestamp;
    }

    // ─── Admin helpers (for testing) ──────────────────────────────────────────

    function setEpochRewards(uint256 epochNum, uint256 amount) external {
        epochRewards[epochNum] = amount;
        totalRewardPool += amount;
    }

    function setTotalStakedAtEpoch(uint256 epochNum, uint256 amount) external {
        totalStakedAtEpoch[epochNum] = amount;
    }

    function stake(uint256 amount) external {
        stakedBalance[msg.sender] += amount;
    }

    function setPersonalUtilizationLowerBound(uint256 bound) external {
        personalUtilizationLowerBound = bound; // 0 to 10000
    }

    // ─── Epoch math ───────────────────────────────────────────────────────────

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - deployedAt) / EPOCH_DURATION;
    }

    // ─── Claim ────────────────────────────────────────────────────────────────

    /**
     * ╔════════════════════════════════════════════════════════════╗
     * ║  🐛 BUG IS HERE                                          ║
     * ║                                                            ║
     * ║  Flow when personalUtilizationLowerBound = 0:             ║
     * ║  1. rawUserRewards = 100 (non-zero, no revert)             ║
     * ║  2. personalUtilizationRatio = 0                           ║
     * ║  3. userRewards = 100 * 0 / 10000 = 0                     ║
     * ║  4. ← current code: revert("no rewards")                  ║
     * ║     PROBLEM: no storage write → epoch never marked claimed ║
     * ║  5. Next epoch: ratio could be > 0 → user claims again!   ║
     * ║                                                            ║
     * ║  Actually the check order is:                              ║
     * ║  rawRewards == 0 → revert (no store)                       ║
     * ║  apply ratio → userRewards == 0 → revert (no store)       ║
     * ║  check _hasClaimed → false (never stored 0)               ║
     * ║  store userRewards                                         ║
     * ║                                                            ║
     * ║  FIX: store a dedicated bool flag BEFORE zero-check        ║
     * ║  OR: store a sentinel value (e.g., type(uint256).max - 1)  ║
     * ╚════════════════════════════════════════════════════════════╝
     */
    function claimRewards(address recipient) external {
        uint256 epoch = currentEpoch();
        require(epoch > 0, "TrustBonding: no rewards in first epoch");

        uint256 prevEpoch = epoch - 1;

        // Step 1: Calculate raw reward (pro-rata share)
        uint256 rawRewards = _calcRawRewards(msg.sender, prevEpoch);
        if (rawRewards == 0) {
            revert("TrustBonding: no rewards to claim");
        }

        // Step 2: Apply personal utilization multiplier
        uint256 utilization = _getPersonalUtilization(msg.sender);
        uint256 userRewards = (rawRewards * utilization) / BASIS_POINTS;

        // Step 3: Check zero after utilization
        if (userRewards == 0) {
            revert("TrustBonding: no rewards after utilization");
            // ❌ BUG: we revert WITHOUT marking epoch as claimed
            // If utilization later becomes non-zero, user can claim again
        }

        // Step 4: Check double claim
        // ❌ BUG: _hasClaimedRewardsForEpoch checks > 0, but we never
        //         write 0 (we revert above). So if we fix step 3 to not
        //         revert, and write 0, this check still fails.
        if (_hasClaimedRewardsForEpoch(msg.sender, prevEpoch)) {
            revert("TrustBonding: already claimed");
        }

        // Step 5: Store and transfer
        totalClaimedRewardsForEpoch[prevEpoch] += userRewards;
        userClaimedRewardsForEpoch[msg.sender][prevEpoch] = userRewards;

        rewardBalance[recipient] += userRewards;
        emit RewardsClaimed(msg.sender, recipient, userRewards);
    }

    /**
     * ╔════════════════════════════════════════════════════════════╗
     * ║  🐛 ROOT OF THE DOUBLE-CLAIM BUG                         ║
     * ║                                                            ║
     * ║  Uses amount > 0 as proxy for "has claimed"               ║
     * ║  A zero-amount claim is indistinguishable from no claim   ║
     * ║                                                            ║
     * ║  FIX: use a dedicated mapping(address => mapping(uint256 => bool))║
     * ╚════════════════════════════════════════════════════════════╝
     */
    function _hasClaimedRewardsForEpoch(address user, uint256 epochNum) internal view returns (bool) {
        return userClaimedRewardsForEpoch[user][epochNum] > 0; // ← BUG
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _calcRawRewards(address user, uint256 epochNum) internal view returns (uint256) {
        uint256 total = totalStakedAtEpoch[epochNum];
        if (total == 0) return 0;
        uint256 userStake = stakedBalance[user];
        return (epochRewards[epochNum] * userStake) / total;
    }

    function _getPersonalUtilization(address /* user */ ) internal view returns (uint256) {
        return personalUtilizationLowerBound;
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function hasClaimed(address user, uint256 epochNum) external view returns (bool) {
        return _hasClaimedRewardsForEpoch(user, epochNum);
    }

    function pendingRewards(address user) external view returns (uint256 raw, uint256 afterUtil) {
        uint256 epoch = currentEpoch();
        if (epoch == 0) return (0, 0);
        uint256 prevEpoch = epoch - 1;
        raw = _calcRawRewards(user, prevEpoch);
        afterUtil = (raw * _getPersonalUtilization(user)) / BASIS_POINTS;
    }
}
