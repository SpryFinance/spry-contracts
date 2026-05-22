// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";
import {SpryFeeParams} from "../../contracts/libs/SpryFeeTypes.sol";
import {HookMiner} from "../../script/HookMiner.sol";

/// @title AllTiersMarginalFeeTest
/// @notice MarginalFeeTest exercises the integral-mode math against the
///         BLUE-CHIP (tier 2) parameter set in detail; this suite spot-
///         checks the SAME integral path against the other four tiers'
///         coefficient sets to make sure the tier registry is self-
///         consistent on every tier, not just the canonical one.
///
///         For each tier the suite verifies:
///           - safe-zone growth pays exactly the tier's `safeFee`
///           - cap-zone growth pays exactly the tier's `capFee`
///           - alert / danger growth stays in (safeFee, capFee]
///           - UNWIND from anywhere always pays `safeFee`
///         The tier params themselves come from `SpryHook.tierParams(t)`,
///         so any drift between the hook's registry and what SmartFeeLib
///         consumes would surface as a test failure here.
contract AllTiersMarginalFeeTest is Test {
    SpryHook internal hook;

    uint8 internal constant TIER_COUNT = 5;

    function setUp() public {
        IPoolManager manager = IPoolManager(new PoolManager(address(this)));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");
    }

    // ------------------------------------------------------------------
    // Safe-zone growth pays each tier's safeFee.
    // ------------------------------------------------------------------

    function testAllTiersGrowthInSafeReturnsSafeFee() public view {
        for (uint8 t = 0; t < TIER_COUNT; ++t) {
            SpryFeeParams memory p = hook.tierParams(t);

            // Interior point of the safe zone on the right side.
            int256 inside = int256(p.safeHigh) / 2;
            uint24 m = SmartFeeLib.marginalFee(int256(0), inside, p);
            assertEq(uint256(m), uint256(p.safeFee), _err(t, "right safe growth"));

            // Mirror on the left side.
            int256 insideL = int256(p.safeLow) / 2;
            uint24 ml = SmartFeeLib.marginalFee(int256(0), insideL, p);
            assertEq(uint256(ml), uint256(p.safeFee), _err(t, "left safe growth"));
        }
    }

    // ------------------------------------------------------------------
    // Cap-zone growth (interval lying entirely past dangerHigh) pays
    // the tier's capFee with no path mixing.
    // ------------------------------------------------------------------

    function testAllTiersGrowthInCapReturnsCapFee() public view {
        for (uint8 t = 0; t < TIER_COUNT; ++t) {
            SpryFeeParams memory p = hook.tierParams(t);

            // Interval well past the right danger edge.
            int256 lo = int256(p.dangerHigh) + 100;
            int256 hi = lo + 100;
            uint24 m = SmartFeeLib.marginalFee(lo, hi, p);
            assertEq(uint256(m), uint256(p.capFee), _err(t, "right cap growth"));

            // Mirror on the left side.
            int256 loL = int256(p.dangerLow) - 100;
            int256 hiL = loL - 100;
            uint24 ml = SmartFeeLib.marginalFee(loL, hiL, p);
            assertEq(uint256(ml), uint256(p.capFee), _err(t, "left cap growth"));
        }
    }

    // ------------------------------------------------------------------
    // Alert-zone interior — marginal must sit strictly between safeFee
    // and capFee for each tier (the linear ramp covers the alert zone).
    // ------------------------------------------------------------------

    function testAllTiersGrowthInAlertBoundedByEndpoints() public view {
        for (uint8 t = 0; t < TIER_COUNT; ++t) {
            SpryFeeParams memory p = hook.tierParams(t);

            // Interval entirely in right alert: midpoint of [safeHigh, alertHigh]
            // ± a small spread.
            int256 mid = (int256(p.safeHigh) + int256(p.alertHigh)) / 2;
            int256 lo = mid - 1;
            int256 hi = mid + 1;
            uint24 m = SmartFeeLib.marginalFee(lo, hi, p);
            assertGt(uint256(m), uint256(p.safeFee), _err(t, "right alert > safeFee"));
            assertLt(uint256(m), uint256(p.capFee),  _err(t, "right alert < capFee"));
        }
    }

    // ------------------------------------------------------------------
    // Danger-zone interior — marginal must sit strictly between safeFee
    // and capFee. (The exponential ramps from alertEdgeFee at alertHigh
    // up to dangerEdgeFee at dangerHigh.)
    // ------------------------------------------------------------------

    function testAllTiersGrowthInDangerBoundedByEndpoints() public view {
        for (uint8 t = 0; t < TIER_COUNT; ++t) {
            SpryFeeParams memory p = hook.tierParams(t);

            // Interval entirely in right danger: midpoint of [alertHigh, dangerHigh]
            // ± a small spread.
            int256 mid = (int256(p.alertHigh) + int256(p.dangerHigh)) / 2;
            int256 lo = mid - 1;
            int256 hi = mid + 1;
            uint24 m = SmartFeeLib.marginalFee(lo, hi, p);
            assertGt(uint256(m), uint256(p.safeFee), _err(t, "right danger > safeFee"));
            assertLe(uint256(m), uint256(p.capFee),  _err(t, "right danger <= capFee"));
        }
    }

    // ------------------------------------------------------------------
    // UNWIND case — same sign, absAfter < absBefore — always returns the
    // tier's safeFee regardless of where the cum starts.
    // ------------------------------------------------------------------

    function testAllTiersUnwindReturnsSafeFee() public view {
        for (uint8 t = 0; t < TIER_COUNT; ++t) {
            SpryFeeParams memory p = hook.tierParams(t);

            // Start deep in danger, unwind toward safe — UNWIND from danger.
            int256 deep = int256(p.dangerHigh) - 1;
            int256 less = int256(p.safeHigh)   / 2;
            uint24 m = SmartFeeLib.marginalFee(deep, less, p);
            assertEq(uint256(m), uint256(p.safeFee), _err(t, "right danger->safe unwind"));

            // Symmetric on the left.
            int256 deepL = int256(p.dangerLow) + 1;
            int256 lessL = int256(p.safeLow)   / 2;
            uint24 ml = SmartFeeLib.marginalFee(deepL, lessL, p);
            assertEq(uint256(ml), uint256(p.safeFee), _err(t, "left danger->safe unwind"));
        }
    }

    // ------------------------------------------------------------------
    // FLIP case — opposite-sign cumBefore/cumAfter. Marginal is bounded
    // below by safeFee (since the unwind half pays exactly that) and
    // above by capFee.
    // ------------------------------------------------------------------

    function testAllTiersFlipBoundedBySafeAndCap() public view {
        for (uint8 t = 0; t < TIER_COUNT; ++t) {
            SpryFeeParams memory p = hook.tierParams(t);

            // Start in left safe, push to right safe (FLIP, both halves
            // covered by safe-zone integration -> exactly safeFee).
            int256 leftSafe  = int256(p.safeLow)  / 2;
            int256 rightSafe = int256(p.safeHigh) / 2;
            uint24 m = SmartFeeLib.marginalFee(leftSafe, rightSafe, p);
            assertEq(uint256(m), uint256(p.safeFee), _err(t, "safe->safe flip"));

            // Start in left safe, push past right alert boundary -> blend.
            int256 rightAlert = int256(p.alertHigh) - 1;
            uint24 m2 = SmartFeeLib.marginalFee(leftSafe, rightAlert, p);
            assertGe(uint256(m2), uint256(p.safeFee), _err(t, "alert flip >= safeFee"));
            assertLt(uint256(m2), uint256(p.capFee),  _err(t, "alert flip < capFee"));
        }
    }

    function _err(uint8 t, string memory tag) internal pure returns (string memory) {
        return string.concat("tier ", _u(uint256(t)), ": ", tag);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        if (v == 1) return "1";
        if (v == 2) return "2";
        if (v == 3) return "3";
        if (v == 4) return "4";
        return "?";
    }
}
