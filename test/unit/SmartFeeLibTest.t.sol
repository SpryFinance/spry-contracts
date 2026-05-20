// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";
import {VirtualReserves} from "../../contracts/libs/VirtualReserves.sol";

contract SmartFeeLibTest is Test {
    /// sqrtPriceX96 for price = 1 (i.e. reserve0 == reserve1).
    uint160 internal constant SQRT_PRICE_1_TO_1 = 1 << 96;

    // ---------------------------------------------------------------------
    // VirtualReserves
    // ---------------------------------------------------------------------
    function testVirtualReservesAtUnityPrice() public pure {
        (uint256 r0, uint256 r1) = VirtualReserves.fromState(SQRT_PRICE_1_TO_1, 1000);
        assertEq(r0, 1000, "reserve0 at 1:1");
        assertEq(r1, 1000, "reserve1 at 1:1");
    }

    function testVirtualReservesAtQuadruplePrice() public pure {
        // price = 4 ⇒ sqrtPrice = 2 ⇒ sqrtPriceX96 = 2 * 2^96
        uint160 sqrtP = uint160(2 * (uint256(1) << 96));
        (uint256 r0, uint256 r1) = VirtualReserves.fromState(sqrtP, 1000);
        assertEq(r0, 500, "reserve0 halved at price=4");
        assertEq(r1, 2000, "reserve1 doubled at price=4");
        // K is preserved: 500 * 2000 = 1_000_000 = 1000 * 1000
    }

    function testVirtualReservesZeroLiquidity() public pure {
        (uint256 r0, uint256 r1) = VirtualReserves.fromState(SQRT_PRICE_1_TO_1, 0);
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    function testVirtualReservesZeroPrice() public pure {
        (uint256 r0, uint256 r1) = VirtualReserves.fromState(0, 1000);
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    // ---------------------------------------------------------------------
    // SmartFeeLib.getDynamicFee — base fee in safe zone
    // ---------------------------------------------------------------------
    function testFeeSafeZoneExactOutSmall() public pure {
        // amountSpecified = +250 token1 out, zeroForOne=true (so amount1Out=250)
        // delta = -1000 * 250 / 1250 = -200 → safe zone
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, int256(250));
        assertEq(fee, 3000, "safe zone returns 3 bps == 3000 pips");
    }

    function testFeeSafeZoneRightExactOutSmall() public pure {
        // zeroForOne=false (token1 → token0), amountSpecified=+250 (amount0Out=250)
        // delta = 1000 * 250 / 1000 = +250 → safe zone (-250..334)
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(250));
        assertEq(fee, 3000);
    }

    function testFeeZeroAmountSpecifiedReturnsBaseFee() public pure {
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, int256(0));
        assertEq(fee, 3000, "zero amount -> safe-zone fee");
    }

    function testFeeZeroLiquidityReturnsBaseFee() public pure {
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 0, true, int256(1e18));
        assertEq(fee, 3000, "zero liquidity -> safe-zone fee");
    }

    // ---------------------------------------------------------------------
    // Alert zone
    // ---------------------------------------------------------------------
    function testFeeLeftAlertExactOut() public pure {
        // amount1Out=400, delta = -1000 * 400 / 1400 = -285
        // _linear(-68000, -14000, -285) = (-68000*-285 - 14_000_000)/1e6
        //   = (19_380_000 - 14_000_000)/1e6 = 5
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, int256(400));
        assertEq(fee, 5_000, "left alert ~5 bps");
    }

    function testFeeLeftAlertBoundaryExactOut() public pure {
        // amount1Out=1000, delta = -1000 * 1000 / 2000 = -500 ⇒ alert/danger boundary, fee=20
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, int256(1000));
        assertEq(fee, 20_000);
    }

    function testFeeRightAlertBoundaryExactOut() public pure {
        // zeroForOne=false ⇒ amount0Out=1000, delta = 1000 * 1000 / 1000 = 1000 ⇒ boundary
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(1000));
        assertEq(fee, 20_000);
    }

    function testFeeRightAlertInteriorExactOut() public pure {
        // amount0Out=500, delta=+500 → right alert
        // _linear(25370, -5370, 500) = (25370*500 - 5_370_000)/1e6 = (12_685_000 - 5_370_000)/1e6 = 7
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(500));
        assertEq(fee, 7_000);
    }

    // ---------------------------------------------------------------------
    // Danger zone
    // ---------------------------------------------------------------------
    function testFeeLeftDangerInterior() public pure {
        // amount1Out=3000, delta=-1000*3000/4000=-750 → left danger zone
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, int256(3000));
        assertGt(fee, 20_000);
        assertLe(fee, 50_000);
    }

    function testFeeRightDangerInterior() public pure {
        // amount0Out=2500, delta=2500 → right danger
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(2500));
        assertGt(fee, 20_000);
        assertLe(fee, 50_000);
    }

    function testFeeFallbackBeyondCap() public pure {
        // amount0Out=5001 with reserves 1000/1000 → delta=5001 → fallback 55
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(5001));
        assertEq(fee, 55_000, "55 bps = 55_000 pips");
    }

    // ---------------------------------------------------------------------
    // Exact-in path (negative amountSpecified) — uses the no-fee constant-
    // product output formula to derive the implied output, then runs the
    // standard delta math against that derived output.
    // ---------------------------------------------------------------------
    function testFeeExactInSmall() public pure {
        // exactIn 334 token0 → amount1Out = 334*1000/(1000+334) = 250
        // delta = -200 → safe zone
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, -int256(334));
        assertEq(fee, 3000);
    }

    function testFeeExactInLargeReachesDanger() public pure {
        // exactIn 5000 token0 with reserves 1000/1000:
        // amount1Out = 5000 * 1000 / 6000 = 833
        // delta = -1000 * 833 / 1833 = -454 → still alert
        // We expect fee in alert range (3..20)
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, -int256(5000));
        assertGt(fee, 3_000);
        assertLt(fee, 20_000);
    }

    // ---------------------------------------------------------------------
    // Fuzz: fee is always in [0, 55_000] regardless of inputs
    // ---------------------------------------------------------------------
    function testFuzzFeeBounded(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        bool zeroForOne,
        int128 amountSpecified
    ) public pure {
        liquidity = uint128(bound(uint256(liquidity), 1, 1e30));
        sqrtPriceX96 = uint160(bound(uint256(sqrtPriceX96), 1 << 32, type(uint160).max - 1));
        amountSpecified = int128(bound(int256(amountSpecified), -1e24, 1e24));

        uint24 fee = SmartFeeLib.getDynamicFee(
            sqrtPriceX96,
            liquidity,
            zeroForOne,
            int256(amountSpecified)
        );
        assertLe(fee, 55_000, "fee never exceeds 55_000 pips");
    }

    // ---------------------------------------------------------------------
    // Extreme reserve ratio: a naive implementation that first computed an
    // intermediate spot price (1e6 * reserve0 / reserve1) would truncate to
    // zero here and panic on the next division. The library's direct delta
    // formula has no such failure mode at any reserve ratio.
    // ---------------------------------------------------------------------
    function testExtremeRatioDoesNotPanic() public pure {
        // sqrtPrice corresponding to massive imbalance — should not div-by-zero.
        // Pick a sqrtPrice well above 2^96 (price > 1) and a small swap.
        uint160 sqrtP = uint160((uint256(1) << 96) * 1_000_000);
        // virtual reserves: r0 ≈ liquidity/1e6, r1 ≈ liquidity*1e6
        uint24 fee = SmartFeeLib.getDynamicFee(sqrtP, 1e18, true, -int256(1));
        // Just assert it returns *something* sane; the bug would have panicked.
        assertLe(fee, 55_000);
    }

    // ---------------------------------------------------------------------
    // Boundary continuity — the linear-zone coefficients are tuned so the
    // curve is continuous at every safe<->alert<->danger transition in
    // spite of the asymmetric delta formula. These tests pin that
    // property: any future change to A_*, B_*, or the delta formula that
    // breaks continuity will trip a regression.
    // ---------------------------------------------------------------------

    /// @dev At delta = -250 (safe<->left-alert boundary) the fee must be
    ///      EXACTLY 3 bps (3000 pips) from either side of the dispatch.
    ///      Construct a swap that lands at delta = -250 by solving
    ///      `-1000 * x / (R + x) = -250` → x = R/3.
    function testFeeContinuousAtLeftSafeAlertBoundary() public pure {
        // R = 1500 picked so x = 500 makes delta = -1000 * 500 / 2000 = -250.
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1500, true, int256(500));
        assertEq(fee, 3_000, "safe-zone fee at delta = -250");
    }

    /// @dev At delta = +334 (safe<->right-alert boundary) the fee must be
    ///      3 bps (truncated). Construct delta = +334 via amount0Out = 334
    ///      against reserve0 = 1000 (`+1000 * 334 / 1000 = 334`).
    function testFeeContinuousAtRightSafeAlertBoundary() public pure {
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(334));
        assertEq(fee, 3_000, "safe-zone fee at delta = +334");
    }

    /// @dev Just past the boundary (delta = -251) the left-alert linear
    ///      formula must still return ~3 bps (3 after integer truncation,
    ///      no jump). Verifies the safe<->alert kink is at the bps-of-1000
    ///      grid resolution, not a real discontinuity.
    function testFeeNoJumpJustPastLeftSafeBoundary() public pure {
        // R chosen so delta = -1000 * 1000 / 3990 = -250.xxx → -250 (still safe)
        // and a second swap producing -251 (alert) → first iter of linear.
        // Simpler: at the alert side just inside, compute the linear fee.
        // amount1Out=251 against R1=750 gives delta = -1000 * 251 / 1001 = -250.xxx (still safe?)
        // We construct explicitly with amount/(R+amount) ratio = 251/1000:
        // amount = 251, R = 749 -> delta = -1000 * 251 / 1000 = -251. Alert.
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 749, true, int256(251));
        // _linear(-68000, -14000, -251) = (17068000 - 14000000)/1e6 = 3 (truncated).
        assertEq(fee, 3_000, "linear fee at delta = -251 still truncates to 3 bps");
    }

    /// @dev At delta = -500 (alert<->danger boundary) the linear formula
    ///      must return exactly 20 bps (20_000 pips).
    function testFeeContinuousAtLeftAlertDangerBoundary() public pure {
        // amount/(R+amount)=500/1000 → amount = R, so set R=1000, amount=1000.
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, true, int256(1000));
        assertEq(fee, 20_000, "alert->danger fee at delta = -500 is 20 bps");
    }

    /// @dev At delta = +1000 (alert<->danger boundary) the linear formula
    ///      must return exactly 20 bps. amount0Out = R, delta = +1000.
    function testFeeContinuousAtRightAlertDangerBoundary() public pure {
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(1000));
        assertEq(fee, 20_000, "alert->danger fee at delta = +1000 is 20 bps");
    }

    /// @dev Outside the configured exp-zone caps the fallback returns
    ///      EXACTLY 55 bps. Spot-check the right tail (delta > 5000).
    ///      The right danger zone covers (1000, 5000]; anything beyond
    ///      hits the fallback.
    function testFeeFallbackAtRightCap() public pure {
        // amount0Out > 5*R produces delta > 5000.
        uint24 fee = SmartFeeLib.getDynamicFee(SQRT_PRICE_1_TO_1, 1000, false, int256(5001));
        assertEq(fee, 55_000, "fallback fee 55 bps fires past delta = 5000");
    }
}
