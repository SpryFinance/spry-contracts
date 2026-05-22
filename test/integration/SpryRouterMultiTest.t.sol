// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract SpryRouterMultiTest is Test {
    IPoolManager public manager;
    SpryHook public hook;
    SpryRouter public router;
    PoolModifyLiquidityTest public modifyRouter;

    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    ERC20Mock public tokenC;

    PoolKey public keyAB;
    PoolKey public keyBC;

    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        modifyRouter = new PoolModifyLiquidityTest(manager);
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));

        // Three tokens with distinct addresses; we don't need to sort them
        // because the router sorts per-hop.
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        tokenC = new ERC20Mock();
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
        vm.label(address(tokenC), "TokenC");

        deal(address(tokenA), address(this), 1e30);
        deal(address(tokenB), address(this), 1e30);
        deal(address(tokenC), address(this), 1e30);
        tokenA.approve(address(modifyRouter), type(uint256).max);
        tokenB.approve(address(modifyRouter), type(uint256).max);
        tokenC.approve(address(modifyRouter), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted);

        keyAB = _buildKey(tokenA, tokenB);
        keyBC = _buildKey(tokenB, tokenC);

        manager.initialize(keyAB, 1 << 96);
        manager.initialize(keyBC, 1 << 96);

        _addFullRange(keyAB, 1e22);
        _addFullRange(keyBC, 1e22);
    }

    function _buildKey(ERC20Mock x, ERC20Mock y) internal view returns (PoolKey memory) {
        (address t0, address t1) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _addFullRange(PoolKey memory key, int256 liquidityDelta) internal {
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

    // ---------------------------------------------------------------------
    // Multi-hop swap A → B → C
    // ---------------------------------------------------------------------
    function testTwoHopAtoBtoC() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 inA = tokenA.balanceOf(address(this));
        uint256 outC = tokenC.balanceOf(address(this));

        uint256 amountIn = 1e18;
        uint256 amountOut = router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            amountIn,
            1,
            address(this),
            block.timestamp + 100
        );

        assertEq(inA - tokenA.balanceOf(address(this)), amountIn, "A paid");
        assertEq(tokenC.balanceOf(address(this)) - outC, amountOut, "C received");
        assertGt(amountOut, 0);
        // Two hops at ~0.3% each: amountOut should be slightly less than (amountIn * 0.994)
        assertLt(amountOut, amountIn);
    }

    function testTwoHopCtoBtoA() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 inC = tokenC.balanceOf(address(this));
        uint256 outA = tokenA.balanceOf(address(this));

        uint256 amountOut = router.swapExactInput(
            Currency.wrap(address(tokenC)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );

        assertEq(inC - tokenC.balanceOf(address(this)), 1e18);
        assertEq(tokenA.balanceOf(address(this)) - outA, amountOut);
        assertGt(amountOut, 0);
    }

    // ---------------------------------------------------------------------
    // Degenerate path: length 1 should work identically to single-hop
    // ---------------------------------------------------------------------
    function testSingleHopViaMultiAPI() public {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        uint256 outBefore = tokenB.balanceOf(address(this));
        uint256 amountOut = router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );
        assertEq(tokenB.balanceOf(address(this)) - outBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testEmptyPathReverts() public {
        PathKey[] memory path = new PathKey[](0);
        vm.expectRevert(SpryRouter.EmptyPath.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );
    }

    function testMultiHopSlippageReverts() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        vm.expectRevert(SpryRouter.InsufficientOutput.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            type(uint256).max,
            address(this),
            block.timestamp + 100
        );
    }

    function testMultiHopDeadlineReverts() public {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        vm.expectRevert(SpryRouter.Expired.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp - 1
        );
    }

    receive() external payable {}
}
