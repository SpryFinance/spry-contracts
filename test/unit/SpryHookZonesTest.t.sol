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
import {HookMiner} from "../../contracts/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";

/// @notice Drives SmartFeeLib through every fee zone FROM THE HOOK
///         INLINING SITE. Calling the library through its own test contract
///         already covers it directly; this suite makes sure the hook's
///         inlined copy also exercises each branch, which is what forge
///         coverage measures per source file under the no-via_ir profile.
contract SpryHookZonesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    PoolKey internal key;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint24 internal constant OVERRIDE_FLAG = 0x400000;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager)
        );
        hook = new SpryHook{salt: salt}(manager);
        require(address(hook) == predicted, "hook addr mismatch");

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add a reasonable seed so reserves = 1e22 each (virtual).
        router.addLiquidity(key, 1e22, 1e22, 0, 0, address(this), block.timestamp + 100);
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
        // amount0Out ~ reserve0 -> delta near 1000. Actual reserve isn't
        // exactly 1e22 because LiquidityAmounts at full range rounds up
        // slightly, so we land just under 1000 and the linear formula
        // gives a fee in the 19-20 bps range (19_000-20_000 pips).
        uint24 fee = _callBeforeSwap(false, int256(1e22));
        assertGt(fee, 17_000);
        assertLe(fee, 20_000);
    }

    function testHookBeforeSwapLeftAlertNearBoundary() public {
        // Symmetric test for left side. amount1Out ~ reserve1 -> delta near -500.
        uint24 fee = _callBeforeSwap(true, int256(1e22));
        assertGt(fee, 17_000);
        assertLe(fee, 20_000);
    }

    function testHookBeforeSwapRightDangerZone() public {
        // amount0Out = 3e22 (3x reserve) -> delta = 3000 -> right danger zone
        uint24 fee = _callBeforeSwap(false, int256(3e22));
        assertGt(fee, 20_000);
        assertLe(fee, 50_000);
    }

    function testHookBeforeSwapLeftDangerZone() public {
        // amount1Out = 3e22 -> delta = -1000 * 3e22 / 4e22 = -750 -> left danger
        uint24 fee = _callBeforeSwap(true, int256(3e22));
        assertGt(fee, 20_000);
        assertLe(fee, 50_000);
    }

    function testHookBeforeSwapFallbackBeyondCap() public {
        // amount0Out > 5x reserve -> delta > 5000 -> fallback 55_000 pips
        uint24 fee = _callBeforeSwap(false, int256(6e22));
        assertEq(fee, 55_000);
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
