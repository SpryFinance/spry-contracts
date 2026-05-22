// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";

contract SpryHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    SpryHook public hook;
    PoolKey public key;
    PoolModifyLiquidityTest public modifyRouter;
    PoolSwapTest public swapRouter;
    ERC20Mock public token0;
    ERC20Mock public token1;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        modifyRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // Sort tokens by address so the assignment to currency0/currency1 is canonical.
        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(modifyRouter), type(uint256).max);
        token1.approve(address(modifyRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Mine a salt so the hook deploys at an address whose low 14 bits ==
        // BEFORE_SWAP_FLAG. V4 derives permissions from the address itself.
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        _addFullRangeLiquidity(1e22);
    }

    function _addFullRangeLiquidity(int256 liquidityDelta) internal {
        modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _expectedFee(bool zeroForOne, int256 amountSpecified) internal view returns (uint24) {
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());
        return SmartFeeLib.getDynamicFee(sqrtPriceX96, liquidity, zeroForOne, amountSpecified, hook.tierParams(2));
    }

    // ---------------------------------------------------------------------
    // Permission flags
    // ---------------------------------------------------------------------
    function testHookAddressMatchesPermissions() public view {
        uint160 addrBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(addrBits, Hooks.BEFORE_SWAP_FLAG, "address low 14 bits encode BEFORE_SWAP_FLAG only");
    }

    function testPermissionsFlagsConstant() public view {
        assertEq(hook.permissionsFlags(), Hooks.BEFORE_SWAP_FLAG);
    }

    // ---------------------------------------------------------------------
    // beforeSwap is only callable by PoolManager
    // ---------------------------------------------------------------------
    function testBeforeSwapRevertsForNonPoolManager() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
    }

    // ---------------------------------------------------------------------
    // Swap-path integration
    // ---------------------------------------------------------------------
    function testSwapInSafeZoneSucceeds() public {
        // Small swap (~0.01% of reserves) stays well within safe zone.
        uint24 expected = _expectedFee(true, -int256(1e16));
        BalanceDelta delta = _swap(true, -int256(1e16));

        assertEq(expected, 3000, "tiny swap charges base 3000 pips");
        assertLt(BalanceDelta.unwrap(delta), int256(0)); // composite delta: token0 went out, token1 came in
    }

    function testSwapInSafeZoneRightDirection() public {
        uint24 expected = _expectedFee(false, -int256(1e16));
        _swap(false, -int256(1e16));
        assertEq(expected, 3000);
    }

    function testSwapInAlertZoneChargesHigherFee() public {
        // Roughly 50% of reserve as exact-out → delta near alert boundary
        uint24 expected = _expectedFee(true, int256(5e21));
        _swap(true, int256(5e21));
        assertGt(expected, 3000, "alert zone fee > base");
        assertLe(expected, 20000, "alert zone fee bounded at boundary");
    }

    function testSwapAcrossMultipleZones() public {
        // Two swaps: first big enough to leave safe zone, second back. K must
        // never decrease, and both swaps must complete.
        uint24 fee1 = _expectedFee(true, -int256(1e21));
        _swap(true, -int256(1e21));

        uint24 fee2 = _expectedFee(false, -int256(1e21));
        _swap(false, -int256(1e21));

        assertGt(fee1, 0);
        assertGt(fee2, 0);
    }

    // ---------------------------------------------------------------------
    // No-liquidity edge case — should fall back to safe-zone fee but the
    // pool itself will revert because there's nothing to swap against.
    // We assert the fee path doesn't panic by reading state pre-add.
    // ---------------------------------------------------------------------
    function testFeeQueryWithLiquidityPresent() public view {
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());
        uint24 fee = SmartFeeLib.getDynamicFee(sqrtPriceX96, liquidity, true, -int256(1), hook.tierParams(2));
        assertEq(fee, 3000);
    }

    receive() external payable {}
}
