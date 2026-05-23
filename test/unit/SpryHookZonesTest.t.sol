// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Drives SmartFeeLib through every fee zone FROM THE HOOK
///         INLINING SITE. Calling the library through its own test contract
///         already covers it directly; this suite makes sure the hook's
///         inlined copy also exercises each branch, which is what forge
///         coverage measures per source file under the no-via_ir profile.
///
///         Integral-mode note: every swap here runs against a fresh pool
///         (cumBefore = 0), so the fee returned by `beforeSwap` is the
///         INTEGRAL average of the curve over [0, delta], not the rate at
///         the endpoint. A delta deep in the danger zone therefore yields
///         a marginal somewhere between safeFee and dangerEdgeFee — not
///         the point-evaluated dangerEdgeFee that an end-rate model would
///         return. The assertions below reflect the integral-average
///         behavior; the per-zone code paths are still exercised because
///         `_integral` stitches piecewise across whichever zones the
///         [0, delta] interval intersects.
contract SpryHookZonesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    PoolKey internal key;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint24 internal constant OVERRIDE_FLAG = 0x400000;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add a reasonable seed so reserves = 1e22 each (virtual).
        lp.addLiquidity(key, 1e22, 1e22, address(this));
    }

    function _callBeforeSwap(bool zeroForOne, int256 amountSpecified) internal returns (uint24 fee) {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? uint160(4295128739 + 1) : type(uint160).max - 1
        });
        vm.prank(address(manager));
        ( , , uint24 raw) = hook.beforeSwap(address(this), key, p, "");
        // Strip the override flag bit so the test asserts the raw pip value.
        fee = raw & ~OVERRIDE_FLAG;
    }

    // ------------------------------------------------------------------
    // Each zone, exercised via the hook (so SmartFeeLib's branches at the
    // hook's inlined call site are recorded as covered by forge coverage)
    // ------------------------------------------------------------------

    function testHookBeforeSwapSafeZone() public {
        // Tiny exactIn => delta close to 0 => safe-zone fee (3 bps -> 3000 pips)
        uint24 fee = _callBeforeSwap(true, -int256(1e15));
        assertEq(fee, 3000);
    }

    function testHookBeforeSwapRightAlertZone() public {
        // exactOut amountOut = 5e21 against 1e22 reserve -> amount0Out=5e21
        // delta = 1000 * 5e21 / 1e22 = 500 -> right alert
        uint24 fee = _callBeforeSwap(false, int256(5e21));
        assertGt(fee, 3000, "above safe-zone");
        assertLe(fee, 20_000, "at or below alert/danger boundary");
    }

    function testHookBeforeSwapLeftAlertZone() public {
        // exactOut amount1Out = 7e21 (token0->token1 swap, zeroForOne=true)
        // delta = -1000 * 7e21 / (1e22 + 7e21) = -411 -> left alert
        uint24 fee = _callBeforeSwap(true, int256(7e21));
        assertGt(fee, 3000);
        assertLe(fee, 20_000);
    }

    function testHookBeforeSwapRightAlertNearBoundary() public {
        // amount0Out ~ reserve0 -> delta near 1000. Integral over [0, ~1000]
        // averages safe (3000) and alert (3000→20_000 ramp). The marginal
        // lands around 8_600 pips. Assert it is comfortably above the safe-
        // zone constant but below the alert→danger boundary rate.
        uint24 fee = _callBeforeSwap(false, int256(1e22));
        assertGt(fee, 3_000, "above safe-zone average");
        assertLt(fee, 20_000, "below alert/danger boundary rate");
    }

    function testHookBeforeSwapLeftAlertNearBoundary() public {
        // Symmetric to the right-side test on the left. amount1Out ~ reserve1
        // → delta near −500. Integral averages safe + left-alert; marginal
        // lands around 7_200 pips.
        uint24 fee = _callBeforeSwap(true, int256(1e22));
        assertGt(fee, 3_000);
        assertLt(fee, 20_000);
    }

    function testHookBeforeSwapRightDangerZone() public {
        // amount0Out = 3e22 (3x reserve) -> delta ~ 3000 -> right danger zone.
        // Integral over [0, 3000] crosses safe + full alert + part of danger,
        // averaging to a value above the alert ramp's midpoint but well
        // below the danger-edge rate (~50_000).
        uint24 fee = _callBeforeSwap(false, int256(3e22));
        assertGt(fee, 3_000);
        assertLt(fee, 50_000);
    }

    function testHookBeforeSwapLeftDangerZone() public {
        // amount1Out = 3e22 -> delta = -1000 * 3e22 / 4e22 = -750 -> left
        // danger. Integral covers safe + full left-alert + part of left-
        // danger; marginal lands around 13_000 pips.
        uint24 fee = _callBeforeSwap(true, int256(3e22));
        assertGt(fee, 3_000);
        assertLt(fee, 50_000);
    }

    function testHookBeforeSwapFallbackBeyondCap() public {
        // amount0Out > 5x reserve -> delta > 5000 -> the integral covers
        // safe + alert + full danger + a sliver of cap. The marginal is
        // dominated by the lower-rate zones, landing around 32_000 pips
        // — between the alert→danger boundary and the cap. Assert the cap-
        // zone branch IS exercised by demanding the marginal exceeds the
        // alert-ramp's max (we couldn't get there without traversing
        // danger + cap) while remaining strictly under the capFee constant.
        uint24 fee = _callBeforeSwap(false, int256(6e22));
        assertGt(fee, 20_000, "marginal averages well past the alert ramp");
        assertLt(fee, 55_000, "average is strictly below cap rate");
    }

    function testHookBeforeSwapExactInLeftAlert() public {
        // exactIn 1e22 token0 with reserve 1e22 -> amount1Out (no fee) = 5e21
        // delta = -1000 * 5e21 / 1.5e22 = -333 -> just into left alert
        uint24 fee = _callBeforeSwap(true, -int256(1e22));
        assertGt(fee, 3000);
        assertLe(fee, 20_000);
    }

    function testHookBeforeSwapZeroAmountReturnsBase() public {
        uint24 fee = _callBeforeSwap(true, int256(0));
        assertEq(fee, 3000, "zero amountSpecified -> safe-zone fee");
    }

    // -----------------------------------------------------------------
    // poolWindow() getter — verifies that the public view reflects the
    // internal `_poolWindow` mapping the hook updates on every swap.
    // The getter is exercised 128k times per invariant by the fuzz
    // campaign; this test gives it a deterministic regression target
    // so any change in the getter's return shape is caught immediately.
    // -----------------------------------------------------------------

    function testPoolWindowStartsAtZero() public view {
        // No swap has happened yet; the lazy initialization leaves both
        // fields at their default zero values.
        (uint64 windowStart, int128 signedCum) = hook.poolWindow(key.toId());
        assertEq(uint256(windowStart), 0, "fresh pool: windowStart != 0");
        assertEq(int256(signedCum),    0, "fresh pool: signedCum != 0");
    }

    function testPoolWindowTracksFirstSwap() public {
        // Reserves are ~1e22 each; an amount0Out of 2.5e21 produces
        // delta = 1000 * 2.5e21 / 1e22 ≈ +250 (interior of the safe zone).
        // V4's LiquidityAmounts rounds slightly, so we use a small
        // tolerance on the expected magnitude.
        _callBeforeSwap(false, int256(2.5e21));

        (uint64 windowStart, int128 signedCum) = hook.poolWindow(key.toId());
        assertEq(uint256(windowStart), block.number, "windowStart != block.number after first swap");
        assertGe(int256(signedCum), int256(245), "signedCum below the expected ~+250");
        assertLe(int256(signedCum), int256(255), "signedCum above the expected ~+250");
    }

    function testPoolWindowAccumulatesMultipleSameDirectionSwaps() public {
        // Three small same-direction swaps of ~+100 each. The cumulative
        // grows monotonically inside one window, and the windowStart
        // never advances because we stay in the same block.
        _callBeforeSwap(false, int256(1e21));
        _callBeforeSwap(false, int256(1e21));
        _callBeforeSwap(false, int256(1e21));

        (uint64 windowStart, int128 signedCum) = hook.poolWindow(key.toId());
        assertEq(uint256(windowStart), block.number, "windowStart drifted across same-block swaps");
        // Each individual delta is ~+100, but later swaps shift reserves
        // so the contribution drifts slightly. Pin a generous range
        // around the expected +300.
        assertGe(int256(signedCum), int256(270), "signedCum below the expected ~+300");
        assertLe(int256(signedCum), int256(310), "signedCum above the expected ~+300");
    }

    function testPoolWindowResetsAfterBlockBoundary() public {
        // Push the cum, advance past BLOCK_WINDOW, then push again with
        // a strictly smaller swap. The post-reset signedCum should equal
        // the new swap's delta alone — strictly less than the pre-roll
        // accumulated value.
        _callBeforeSwap(false, int256(2.5e21));  // delta ≈ +250
        (, int128 cumBeforeRoll) = hook.poolWindow(key.toId());
        assertGt(int256(cumBeforeRoll), 0, "first swap did not accumulate");

        vm.roll(block.number + uint256(hook.BLOCK_WINDOW()));
        _callBeforeSwap(false, int256(1e21));  // delta ≈ +100 in the new window

        (uint64 windowStart, int128 signedCum) = hook.poolWindow(key.toId());
        assertEq(uint256(windowStart), block.number, "new-window swap did not refresh windowStart");
        assertLt(int256(signedCum), int256(cumBeforeRoll), "window did not reset across BLOCK_WINDOW boundary");
    }

    // -----------------------------------------------------------------
    // Cum saturation at int128 bounds. Realistic per-swap delta is
    // bounded by ±1000, and int128.max is ~1.7 × 10^38 — reaching it
    // via organic accumulation would require ~10^35 swaps in one
    // window, vastly beyond any conceivable block. The saturation
    // logic is defensive against integer overflow if a bug or storage
    // corruption ever put the cum near the bound, so the only way to
    // exercise it is to vm.store-seed the slot.
    //
    // Storage layout: `_poolWindow` is SpryHook's only mutable state
    // variable, so it lives at slot 0. The mapping value slot for
    // `_poolWindow[pid]` is keccak256(abi.encode(pid, 0)). The
    // PoolWindow struct packs into a single 256-bit slot:
    //   bits [0..63]   : windowStart  (uint64)
    //   bits [64..191] : signedCum    (int128, 2's-complement signed)
    //   bits [192..255]: padding
    // -----------------------------------------------------------------

    function testCumSaturatesAtInt128Max() public {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(0)));

        // Seed signedCum to (int128.max - 100). Any positive delta on
        // the next swap will push cumAfter past int128.max and must
        // be saturated to int128.max by the hook's explicit clamp.
        int128 nearMax = type(int128).max - 100;
        uint256 packed = uint256(uint64(block.number)) | (uint256(uint128(nearMax)) << 64);
        vm.store(address(hook), slot, bytes32(packed));

        // Confirm the seed via the public getter — pins the storage-
        // layout assumption above.
        (uint64 wsSeeded, int128 cumSeeded) = hook.poolWindow(key.toId());
        assertEq(uint256(wsSeeded), block.number, "vm.store windowStart");
        assertEq(int256(cumSeeded), int256(nearMax), "vm.store signedCum");

        // Positive-delta swap. exactOut amount0Out = 5e21 against
        // reserve0 = 1e22 → signedDelta = +500, so cumAfter (int256)
        // = (int128.max - 100) + 500 = int128.max + 400. The clamp
        // in beforeSwap must saturate, not wrap.
        _callBeforeSwap(false, int256(5e21));

        (, int128 cumAfter) = hook.poolWindow(key.toId());
        assertEq(int256(cumAfter), int256(type(int128).max), "cum did not saturate at int128.max");
    }

    function testCumSaturatesAtInt128Min() public {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(0)));

        // Symmetric: seed signedCum to (int128.min + 100) and push it
        // further negative. Saturation must clamp to int128.min.
        int128 nearMin = type(int128).min + 100;
        uint256 packed = uint256(uint64(block.number)) | (uint256(uint128(nearMin)) << 64);
        vm.store(address(hook), slot, bytes32(packed));

        (uint64 wsSeeded, int128 cumSeeded) = hook.poolWindow(key.toId());
        assertEq(uint256(wsSeeded), block.number);
        assertEq(int256(cumSeeded), int256(nearMin));

        // Negative-delta swap. exactOut amount1Out = 5e21 against
        // reserve1 = 1e22 → signedDelta = -1000·5e21/1.5e22 = -333,
        // so cumAfter (int256) = (int128.min + 100) - 333 = int128.min
        // - 233. Saturates to int128.min.
        _callBeforeSwap(true, int256(5e21));

        (, int128 cumAfter) = hook.poolWindow(key.toId());
        assertEq(int256(cumAfter), int256(type(int128).min), "cum did not saturate at int128.min");
    }

    receive() external payable {}
}
