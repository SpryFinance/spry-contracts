// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";
import {SpryFeeParams} from "../../contracts/libs/SpryFeeTypes.sol";

/// @title MarginalFeeTest
/// @notice Direct unit tests for `SmartFeeLib.marginalFee` — the integral-
///         mode dispatch used by SpryHook to price each swap based on the
///         pool's cumulative trajectory. These tests pin:
///
///           - the three behavioral cases (Growth / Unwind / Flip)
///           - per-zone correctness (safe / alert / danger / cap)
///           - boundary stitching across zones
///           - path-independence: splitting a same-trajectory move into
///             N pieces yields (within integer-truncation tolerance) the
///             same total fee paid as one big move
///
///         Tier 2 (BLUE-CHIP) is the canonical test bed; left-side mirror
///         tests confirm symmetry where applicable.
contract MarginalFeeTest is Test {
    function _blueChip() internal pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            safeLow:     -250, safeHigh:    334,
            alertLow:    -500, alertHigh:  1000,
            dangerLow:  -1000, dangerHigh: 5000,
            aLeft:   -68_000_000,  bLeft:   -14_000_000,
            aRight:   25_525_525,  bRight:   -5_525_525,
            aLeftExp:    8_000_000_001_237_896_396_800,
            bLeftExp:    -1_832_581_463_748_310_272,
            aRightExp:  15_905_414_575_956_300_922_880,
            bRightExp:       229_072_682_968_538_784,
            safeFee:   3_000,
            capFee:   55_000
        });
    }

    /// @dev Re-implementation of the area = marginal·interval product, used
    ///      by the path-independence tests below.
    function _area(int256 a, int256 b, SpryFeeParams memory p) internal pure returns (uint256) {
        uint24 m = SmartFeeLib.marginalFee(a, b, p);
        uint256 interval = a < b ? uint256(b - a) : uint256(a - b);
        return uint256(m) * interval;
    }

    // =====================================================================
    // Degenerate / safe-zone cases
    // =====================================================================

    function testZeroIntervalReturnsSafeFee() public pure {
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(0),   int256(0),   p), 3000);
        assertEq(SmartFeeLib.marginalFee(int256(200), int256(200), p), 3000);
        assertEq(SmartFeeLib.marginalFee(int256(-500), int256(-500), p), 3000);
    }

    function testGrowthFromZeroInSafeRightReturnsSafeFee() public pure {
        // 0 → +200, entirely in safe zone [−250, +334]. Marginal = safeFee.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(0), int256(200), p), 3000);
    }

    function testGrowthFromZeroInSafeLeftReturnsSafeFee() public pure {
        // 0 → −200, entirely in safe zone. Marginal = safeFee.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(0), int256(-200), p), 3000);
    }

    function testGrowthInSafeRightReturnsSafeFee() public pure {
        // +100 → +300, entirely in safe (safeHigh=334). Marginal = safeFee.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(100), int256(300), p), 3000);
    }

    // =====================================================================
    // Unwind always charges safeFee, regardless of where the cum sits.
    // =====================================================================

    function testUnwindFromAlertReturnsSafeFee() public pure {
        // +800 (in alert) → +200 (in safe). UNWIND. safeFee.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(800), int256(200), p), 3000);
    }

    function testUnwindFromDangerReturnsSafeFee() public pure {
        // +3000 (deep danger) → +100. UNWIND.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(3000), int256(100), p), 3000);
    }

    function testUnwindLeftReturnsSafeFee() public pure {
        // −800 → −200. Same-sign, abs shrinks. UNWIND.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(-800), int256(-200), p), 3000);
    }

    // =====================================================================
    // Alert-zone growth — integrate the linear ramp.
    // =====================================================================

    function testGrowthEntirelyInRightAlert() public pure {
        // +400 → +600, both in right alert (safeHigh=334, alertHigh=1000).
        // At y=400  feeRate = (25_525_525·400 − 5_525_525_000)/1e6 = 4_685
        // At y=600  feeRate = (25_525_525·600 − 5_525_525_000)/1e6 = 9_790
        // Trapezoid average ≈ (4_685 + 9_790)/2 = 7237.
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(400), int256(600), p);
        // Allow ±5 pip tolerance for integer-truncated antiderivative arithmetic.
        assertApproxEqAbs(uint256(m), 7237, 5);
    }

    function testGrowthCrossingSafeAlertBoundary() public pure {
        // +200 → +500. Path: safe [200,334] (134 wide), alert [334,500] (166 wide).
        // Safe contributes safeFee·134 = 3000·134 = 402_000.
        // Alert at y=334 feeRate=3000, at y=500 feeRate=7237 → trapezoid 850_171.
        // Total ≈ 1_252_171 / 300 = 4_173 (give or take rounding).
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(200), int256(500), p);
        assertApproxEqAbs(uint256(m), 4_173, 5);
    }

    function testGrowthAtRightAlertBoundary() public pure {
        // +1000 boundary: just one tick into alert. Marginal ≈ alertEdgeFee = 20_000.
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(999), int256(1000), p);
        // Single-pip interval near the alert→danger seam.
        assertApproxEqAbs(uint256(m), 19_989, 50);
    }

    // =====================================================================
    // Danger-zone growth — integrate the exponential ramp.
    // =====================================================================

    function testGrowthEntirelyInRightDanger() public pure {
        // +1100 → +1500, both in right danger zone.
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(1100), int256(1500), p);
        // Between alertEdgeFee (20_000) and dangerEdgeFee (50_000).
        assertGt(uint256(m), 20_000);
        assertLt(uint256(m), 50_000);
    }

    function testGrowthSpanningAllZonesRight() public pure {
        // 0 → 5000: full sweep safe → alert → danger.
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(0), int256(5000), p);
        // Sanity: average must lie between safeFee and capFee/dangerEdgeFee.
        assertGt(uint256(m), 3_000);
        assertLt(uint256(m), 50_000);
    }

    // =====================================================================
    // Cap zone — past dangerHigh the curve flattens to capFee.
    // =====================================================================

    function testGrowthEntirelyInCapRight() public pure {
        // +5500 → +6000, both past dangerHigh=5000. Constant capFee.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(5500), int256(6000), p), 55_000);
    }

    function testGrowthCrossingDangerCapBoundary() public pure {
        // +4900 → +5200. Most of the interval is still in danger zone.
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(4900), int256(5200), p);
        // Above dangerEdgeFee=50_000, below capFee=55_000.
        assertGt(uint256(m), 49_000);
        assertLt(uint256(m), 55_000);
    }

    // =====================================================================
    // FLIP — sign-flip behavior is unwind half (safeFee) + growth integral.
    // =====================================================================

    function testFlipPureSafeReturnsSafeFee() public pure {
        // −100 → +100, both halves in safe zone. Weighted = safeFee.
        SpryFeeParams memory p = _blueChip();
        assertEq(SmartFeeLib.marginalFee(int256(-100), int256(100), p), 3000);
    }

    function testFlipWithRightAlertGrowth() public pure {
        // −100 → +500.
        //   areaUnwind = safeFee · 100             = 300_000
        //   areaGrowth = safeFee · 334 + alertArea(334, 500)
        //              = 1_002_000 + ≈ 850_171     ≈ 1_852_171
        //   total / 600                            ≈ 3_587
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(-100), int256(500), p);
        assertApproxEqAbs(uint256(m), 3587, 10);
    }

    function testFlipWithLeftGrowth() public pure {
        // +100 → −500. Mirror of the right-alert flip. Marginal should match
        // within rounding because the curve is asymmetric but BLUE-CHIP is
        // numerically similar on either side of the alert ramp.
        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(100), int256(-500), p);
        // Left growth: 0 → −500 crosses safeLow=−250 (250 wide) and reaches
        //              alertLow=−500 (250 wide).
        //   areaUnwind = safeFee · 100             = 300_000
        //   areaGrowth = safeFee · 250 + alertArea(250, 500)
        //              = 750_000 + 2_875_000       = 3_625_000
        //   total / 600                            ≈ 6541
        assertApproxEqAbs(uint256(m), 6541, 10);
    }

    // =====================================================================
    // Path-independence — the headline property of integral mode.
    //
    // For any monotone trajectory cum0 → cumN, the total "fee paid"
    // (Σ marginal_i · interval_i) is independent of how we partition it,
    // up to per-piece integer truncation (≤ 1 unit of area per division).
    // =====================================================================

    function testPathIndependenceInSafeZone() public pure {
        // Pure safe-zone trajectory: 0 → 200.
        SpryFeeParams memory p = _blueChip();
        uint256 whole = _area(int256(0), int256(200), p);
        uint256 split = _area(int256(0),  int256(50),  p)
                      + _area(int256(50), int256(150), p)
                      + _area(int256(150),int256(200), p);
        // No divisions inside safe zone → exact equality.
        assertEq(whole, split);
    }

    function testPathIndependenceCrossingSafeAlert() public pure {
        // 0 → 700 crosses safeHigh=334. Split into 7 equal pieces of 100.
        //
        // Tolerance derivation (same for every path-independence test): each
        // `marginalFee · interval` recoveries truncates ≤ (interval−1) below
        // the true area; the whole side truncates ≤ (I_whole−1); plus a few
        // ulps per piece from the underlying /1e6 (alert) and /(bExp·1e18)
        // (danger) inside `_integral`. Worst case ≈ 2·I_whole + 3·N.
        SpryFeeParams memory p = _blueChip();
        uint256 whole = _area(int256(0), int256(700), p);

        uint256 split = 0;
        for (int256 i = 0; i < 7; ++i) {
            split += _area(int256(i * 100), int256((i + 1) * 100), p);
        }
        // 2·700 + 3·7 = 1421 — safe upper bound, observed delta ≪ this in
        // practice; the actual error is bounded much more tightly by the
        // path-independence proof, but we use the worst-case bound here.
        assertApproxEqAbs(whole, split, 1500);
    }

    function testPathIndependenceCrossingAllZones() public pure {
        // 0 → 2500 visits safe, alert, and well into danger. 5 equal pieces.
        SpryFeeParams memory p = _blueChip();
        uint256 whole = _area(int256(0), int256(2500), p);

        uint256 split = 0;
        for (int256 i = 0; i < 5; ++i) {
            split += _area(int256(i * 500), int256((i + 1) * 500), p);
        }
        // Bound: 2·2500 + 3·5 ≈ 5015.
        assertApproxEqAbs(whole, split, 5_100);
    }

    function testPathIndependenceLeftSide() public pure {
        // 0 → −1500 (alert→danger left). 6 equal pieces of −250.
        SpryFeeParams memory p = _blueChip();
        uint256 whole = _area(int256(0), int256(-1500), p);

        uint256 split = 0;
        for (int256 i = 0; i < 6; ++i) {
            split += _area(int256(-int256(i) * 250), int256(-int256(i + 1) * 250), p);
        }
        // Bound: 2·1500 + 3·6 ≈ 3018.
        assertApproxEqAbs(whole, split, 3_100);
    }

    function testPathIndependenceFlip() public pure {
        // Flip −300 → +500. Split at zero plus an intermediate stop.
        SpryFeeParams memory p = _blueChip();
        uint256 whole = _area(int256(-300), int256(500), p);

        // Split A: split at zero — flip becomes one unwind + one growth.
        uint256 splitA = _area(int256(-300), int256(0),    p)
                       + _area(int256(0),    int256(500),  p);
        // Bound: 2·800 + 3·2 ≈ 1606.
        assertApproxEqAbs(whole, splitA, 1_700);

        // Split B: split off-center — middle piece is itself a smaller flip.
        uint256 splitB = _area(int256(-300), int256(-50),  p)
                       + _area(int256(-50),  int256(150),  p)
                       + _area(int256(150),  int256(500),  p);
        assertApproxEqAbs(whole, splitB, 1_700);
    }

    function testPathIndependenceUnwindIsPureSafeFee() public pure {
        // Any pure-unwind partition pays safeFee per piece.
        SpryFeeParams memory p = _blueChip();
        // Whole: +800 → +100. Same sign, |after| < |before| → UNWIND, safeFee.
        uint256 whole = _area(int256(800), int256(100), p);  // 700·3000 = 2_100_000
        assertEq(whole, uint256(3_000) * 700);

        uint256 split = _area(int256(800), int256(600), p)   // 200·3000
                      + _area(int256(600), int256(300), p)   // 300·3000
                      + _area(int256(300), int256(100), p);  // 200·3000
        assertEq(whole, split);
    }

    // =====================================================================
    // Fuzz: marginalFee is always ≤ capFee + 1 (ulp from the / interval
    // floor), regardless of input. Confirms no overflow / extreme values.
    // =====================================================================

    function testFuzzMarginalFeeBounded(int128 a, int128 b) public pure {
        // Restrict to realistic cumulative magnitudes (< 50_000 in practice).
        a = int128(bound(int256(a), -50_000, 50_000));
        b = int128(bound(int256(b), -50_000, 50_000));

        SpryFeeParams memory p = _blueChip();
        uint24 m = SmartFeeLib.marginalFee(int256(a), int256(b), p);
        assertLe(uint256(m), uint256(p.capFee));
    }

    // =====================================================================
    // Boundary continuity — marginal at a zone-spanning interval should be
    // between (i.e., a weighted avg of) the rates at the two endpoints.
    // =====================================================================

    function testMarginalBetweenEndpointRatesRight() public pure {
        SpryFeeParams memory p = _blueChip();
        // Interval entirely in right alert.
        uint24 m = SmartFeeLib.marginalFee(int256(400), int256(800), p);
        uint24 rateAt400 = SmartFeeLib.feeForDelta(int256(400), p);
        uint24 rateAt800 = SmartFeeLib.feeForDelta(int256(800), p);
        // m must lie between the endpoint rates (linear ramp ⇒ exactly the mean).
        assertGe(uint256(m), uint256(rateAt400));
        assertLe(uint256(m), uint256(rateAt800));
    }
}
