// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  EXERCISE 1: VotingEscrow — Temporal Underflow                  ║
 * ║                                                                  ║
 * ║  BUG SEVERITY: Critical (production incident 2025-11-18)        ║
 * ║                                                                  ║
 * ║  REAL INCIDENT:                                                  ║
 * ║  A user called increase_amount() 91 seconds AFTER epoch ended.  ║
 * ║  This created checkpoint #11907 with ts > epochEnd.             ║
 * ║  Every subsequent claimRewards() then REVERTED with Panic(0x11) ║
 * ║  because _totalSupply() tried: epochEnd - checkpoint.ts         ║
 * ║  where checkpoint.ts > epochEnd → UNDERFLOW                     ║
 * ║                                                                  ║
 * ║  YOUR TASK:                                                      ║
 * ║  1. Read and understand _totalSupply() below                    ║
 * ║  2. Run the test → it should FAIL (reproducing the bug)         ║
 * ║  3. Fix _totalSupply() using binary search (_find_epoch)        ║
 * ║  4. Run the test again → all tests must PASS                    ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */
contract VotingEscrow {
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 4 * 365 days;

    mapping(uint256 => Point) public point_history;
    mapping(address => mapping(uint256 => Point)) public user_point_history;
    mapping(address => uint256) public user_point_epoch;
    mapping(uint256 => int128) public slope_changes;

    uint256 public epoch;

    // ─── Checkpoint ───────────────────────────────────────────────────────────

    /**
     * @notice Create a new checkpoint (called on every lock/unlock operation)
     * @dev This always writes to point_history[++epoch] with CURRENT block.timestamp
     *      The bug arises because this timestamp may be AFTER the epoch end boundary
     */
    function _checkpoint(address addr, int128 slopeDelta) internal {
        epoch += 1;
        uint256 ts = block.timestamp;
        Point memory newPoint = Point({
            bias: 0,
            slope: slopeDelta,
            ts: ts,
            blk: block.number
        });

        if (epoch > 1) {
            Point memory prev = point_history[epoch - 1];
            uint256 elapsed = ts - prev.ts;
            newPoint.bias = prev.bias - prev.slope * int128(int256(elapsed));
            if (newPoint.bias < 0) newPoint.bias = 0;
        }

        point_history[epoch] = newPoint;

        if (addr != address(0)) {
            user_point_epoch[addr] += 1;
            user_point_history[addr][user_point_epoch[addr]] = newPoint;
        }
    }

    // ─── Historical Supply Calculation ────────────────────────────────────────

    /**
     * @notice Walk forward from a checkpoint to compute supply at time t
     * @dev ASSUMPTION (violated by bug): point.ts <= t
     *      When violated: `t_i - last_point.ts` underflows → Panic(0x11)
     */
    function _supply_at(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory last_point = point;
        uint256 t_i = (last_point.ts / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; ++i) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }

            // ⚠️  BUG IS HERE: if last_point.ts > t_i, this underflows
            // int128(int256(t_i - last_point.ts)) → uint underflow when t_i < last_point.ts
            last_point.bias -= last_point.slope * int128(int256(t_i - last_point.ts));

            if (t_i == t) {
                break;
            }
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            last_point.bias = 0;
        }
        return uint256(uint128(last_point.bias));
    }

    /**
     * ╔═══════════════════════════════════════════════════════════════╗
     * ║  🐛 BUGGY FUNCTION — FIX THIS                               ║
     * ║                                                               ║
     * ║  Current behavior: always picks point_history[epoch]         ║
     * ║  (the LATEST checkpoint, which may have ts > t)              ║
     * ║                                                               ║
     * ║  Required behavior: pick the latest checkpoint where ts <= t ║
     * ║  Hint: use _find_epoch(t) to binary search for correct epoch ║
     * ╚═══════════════════════════════════════════════════════════════╝
     */
    function _totalSupply(uint256 t) internal view returns (uint256) {
        // ❌ BUGGY: always picks latest checkpoint regardless of timestamp
        uint256 _epoch = epoch;
        if (_epoch == 0) return 0;

        Point memory point = point_history[_epoch]; // ← BUG: _epoch might have ts > t

        return _supply_at(point, t);
    }

    /**
     * @notice Binary search: find latest checkpoint index where point_history[i].ts <= t
     * @dev This is the FIX helper — use it in _totalSupply
     * @param t Target timestamp
     * @return The epoch index to use
     */
    function _find_epoch(uint256 t) internal view returns (uint256) {
        uint256 _min = 0;
        uint256 _max = epoch;

        for (uint256 i = 0; i < 128; ++i) {
            if (_min >= _max) break;
            uint256 _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].ts <= t) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    // ─── Public wrappers (used by TrustBonding) ───────────────────────────────

    function totalSupplyAt(uint256 t) external view returns (uint256) {
        return _totalSupply(t);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply(block.timestamp);
    }

    // ─── Simplified lock interface ────────────────────────────────────────────

    function checkpoint() external {
        _checkpoint(address(0), 0);
    }

    function lock(address user, int128 slopeDelta) external {
        _checkpoint(user, slopeDelta);
    }

    function getPointHistory(uint256 _epoch) external view returns (Point memory) {
        return point_history[_epoch];
    }

    function currentEpoch() external view returns (uint256) {
        return epoch;
    }
}
