// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title RecipientIsSelfTest
/// @notice Pins the router's `recipient != address(router)` guard: every
///         entry point that takes a `recipient` parameter rejects
///         `recipient == address(router)` with `InvalidRecipient`. The
///         router has no admin / sweep / rescue function; tokens delivered
///         to it would be permanently stuck.
contract RecipientIsSelfTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    ERC20Mock internal tokenC;

    PoolKey internal keyAB;
    PoolKey internal keyBC;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

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
        ERC20Mock c = new ERC20Mock();
        (tokenA, tokenB, tokenC) = _sortThree(a, b, c);

        deal(address(tokenA), address(this), 1e30);
        deal(address(tokenB), address(this), 1e30);
        deal(address(tokenC), address(this), 1e30);
        tokenA.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);

        keyAB = _erc20Key(tokenA, tokenB);
        keyBC = _erc20Key(tokenB, tokenC);
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);

        lp.addLiquidity(keyAB, 1e22, 1e22, address(this));
        lp.addLiquidity(keyBC, 1e22, 1e22, address(this));
    }

    function _sortThree(ERC20Mock a, ERC20Mock b, ERC20Mock c)
        internal pure returns (ERC20Mock, ERC20Mock, ERC20Mock)
    {
        ERC20Mock[3] memory arr = [a, b, c];
        for (uint256 i = 0; i < 2; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (address(arr[j]) < address(arr[i])) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
        return (arr[0], arr[1], arr[2]);
    }

    function _erc20Key(ERC20Mock x, ERC20Mock y) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(x)),
            currency1: Currency.wrap(address(y)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    // -------------------------------------------------------------------
    // Single-hop entry points
    // -------------------------------------------------------------------

    function testSwapExactInputSingleRejectsSelfRecipient() public {
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactInputSingle(
            keyAB, true, 1e18, 1, address(router), block.timestamp + 100, ""
        );
    }

    function testSwapExactOutputSingleRejectsSelfRecipient() public {
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactOutputSingle(
            keyAB, true, 1e17, type(uint256).max, address(router), block.timestamp + 100, ""
        );
    }

    function testSwapExactInputSingleViaPermit2RejectsSelfRecipient() public {
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactInputSingleViaPermit2(
            keyAB, true, 1e18, 1, address(router), block.timestamp + 100, ""
        );
    }

    function testSwapExactOutputSingleViaPermit2RejectsSelfRecipient() public {
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactOutputSingleViaPermit2(
            keyAB, true, 1e17, type(uint256).max, address(router), block.timestamp + 100, ""
        );
    }

    // -------------------------------------------------------------------
    // Multi-hop entry points
    // -------------------------------------------------------------------

    function _twoHopForwardPath() internal view returns (PathKey[] memory path) {
        path = new PathKey[](2);
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
    }

    function _twoHopReversePath() internal view returns (PathKey[] memory path) {
        // V4-style exactOutput: path[0] = user's input
        path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
    }

    function testSwapExactInputMultiHopRejectsSelfRecipient() public {
        PathKey[] memory path = _twoHopForwardPath();
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)), path, 1e18, 1, address(router), block.timestamp + 100
        );
    }

    function testSwapExactInputMultiHopViaPermit2RejectsSelfRecipient() public {
        PathKey[] memory path = _twoHopForwardPath();
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactInputViaPermit2(
            Currency.wrap(address(tokenA)), path, 1e18, 1, address(router), block.timestamp + 100
        );
    }

    function testSwapExactOutputMultiHopRejectsSelfRecipient() public {
        PathKey[] memory path = _twoHopReversePath();
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactOutput(
            Currency.wrap(address(tokenC)), path, 1e17, type(uint256).max, address(router), block.timestamp + 100
        );
    }

    function testSwapExactOutputMultiHopViaPermit2RejectsSelfRecipient() public {
        PathKey[] memory path = _twoHopReversePath();
        vm.expectRevert(SpryRouter.InvalidRecipient.selector);
        router.swapExactOutputViaPermit2(
            Currency.wrap(address(tokenC)), path, 1e17, type(uint256).max, address(router), block.timestamp + 100
        );
    }

    // -------------------------------------------------------------------
    // Liquidity entry points — REMOVED. Router has no addLiquidity /
    // removeLiquidity / *ViaPermit2 LP functions; LP UX is delegated to
    // Uniswap's PositionManager. The InvalidRecipient guard tested above
    // only applies to the swap entry points that remain on the router.
    // -------------------------------------------------------------------

    // -------------------------------------------------------------------
    // Sanity: a non-self recipient still works (regression guard)
    // -------------------------------------------------------------------

    function testSwapStillSucceedsForNonSelfRecipient() public {
        uint256 out = router.swapExactInputSingle(
            keyAB, true, 1e18, 1, address(this), block.timestamp + 100, ""
        );
        assertGt(out, 0);
    }

    receive() external payable {}
}
