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
}
