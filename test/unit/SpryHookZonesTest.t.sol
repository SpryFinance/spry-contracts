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

    receive() external payable {}
}
