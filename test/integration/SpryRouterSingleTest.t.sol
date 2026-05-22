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
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract SpryRouterSingleTest is Test {
    IPoolManager public manager;
    SpryHook public hook;
    SpryRouter public router;
    PoolModifyLiquidityTest public modifyRouter;
    ERC20Mock public token0;
    ERC20Mock public token1;
    PoolKey public key;

    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        modifyRouter = new PoolModifyLiquidityTest(manager);
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(modifyRouter), type(uint256).max);
        token1.approve(address(modifyRouter), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

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

        manager.initialize(key, 1 << 96);

        modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1e22,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function testExactInputSingleHappyPath() public {
        uint256 balBefore = token1.balanceOf(address(this));
        uint256 amountOut = router.swapExactInputSingle(
            key,
            true, // zeroForOne
            1e18,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");

        assertGt(amountOut, 0, "received non-zero output");
        assertEq(token1.balanceOf(address(this)) - balBefore, amountOut, "balance matches");
    }

    function testExactInputSingleReverseDirection() public {
        uint256 balBefore = token0.balanceOf(address(this));
        uint256 amountOut = router.swapExactInputSingle(
            key,
            false,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");
        assertEq(token0.balanceOf(address(this)) - balBefore, amountOut);
    }

    function testExactInputSingleSlippageReverts() public {
        vm.expectRevert(SpryRouter.InsufficientOutput.selector);
        router.swapExactInputSingle(
            key,
            true,
            1e18,
            type(uint256).max, // slippage floor is impossibly high
            address(this),
            block.timestamp + 100
        ,
        "");
    }

    function testExactInputSingleDeadlineReverts() public {
        vm.expectRevert(SpryRouter.Expired.selector);
        router.swapExactInputSingle(
            key,
            true,
            1e18,
            1,
            address(this),
            block.timestamp - 1
        ,
        "");
    }

    function testExactOutputSingleHappyPath() public {
        uint256 balOutBefore = token1.balanceOf(address(this));
        uint256 balInBefore = token0.balanceOf(address(this));
        uint256 amountIn = router.swapExactOutputSingle(
            key,
            true,
            1e18,
            type(uint256).max,
            address(this),
            block.timestamp + 100
        ,
        "");
        assertEq(token1.balanceOf(address(this)) - balOutBefore, 1e18, "exact-out delivered");
        assertEq(balInBefore - token0.balanceOf(address(this)), amountIn, "input matched");
    }

    function testExactOutputSingleAmountInMaxRevert() public {
        vm.expectRevert(SpryRouter.ExcessiveInput.selector);
        router.swapExactOutputSingle(
            key,
            true,
            1e18,
            1, // unreasonably tight max-in
            address(this),
            block.timestamp + 100
        ,
        "");
    }

    function testUnlockCallbackRevertsForNonPoolManager() public {
        vm.expectRevert(SpryRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    receive() external payable {}
}
