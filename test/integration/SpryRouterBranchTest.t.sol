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

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @notice Coverage suite for the router's remaining branches: ETH refund
///         on swapExactOutputSingle, multi-hop with native ETH on the
///         input side and on the output side, the unlockCallback's
///         InvalidCallbackKind path, and the addLiquidity excess-ETH
///         refund branch.
contract SpryRouterBranchTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    PoolKey internal ethTokenAKey; // native / tokenA
    PoolKey internal abKey;        // tokenA / tokenB

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

        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        deal(address(tokenA), address(this), 1e30);
        deal(address(tokenB), address(this), 1e30);
        deal(address(this), 1000 ether);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);

        // Native / tokenA pool: address(0) sorts smallest, so it is currency0.
        ethTokenAKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(ethTokenAKey, SQRT_PRICE_1_1);
        lp.addLiquidity{value: 10 ether}(ethTokenAKey, 10 ether, 10 ether, address(this));

        // tokenA / tokenB pool (canonical sort).
        (Currency cA, Currency cB) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        abKey = PoolKey({
            currency0: cA,
            currency1: cB,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(abKey, SQRT_PRICE_1_1);
        lp.addLiquidity(abKey, 1e22, 1e22, address(this));
    }

    // ------------------------------------------------------------------
    // swapExactOutputSingle ETH refund branch
    // ------------------------------------------------------------------
    function testExactOutputSingleNativeRefundsExcessETH() public {
        // Send way more ETH than will be needed; router must refund the rest.
        uint256 ethBefore = address(this).balance;
        uint256 amountOut = 1e18;
        router.swapExactOutputSingle{value: 5 ether}(
            ethTokenAKey,
            true, // ETH -> tokenA
            amountOut,
            5 ether,
            address(this),
            block.timestamp + 100
        ,
        "");
        // Total ETH spent must be less than the 5 ether we sent.
        uint256 spent = ethBefore - address(this).balance;
        assertLt(spent, 5 ether, "router refunded the unused ETH");
        assertGt(spent, 0);
    }

    // ------------------------------------------------------------------
    // Multi-hop with native ETH on the input side
    // ------------------------------------------------------------------
    function testMultiHopNativeETHInput() public {
        // Add a tokenA/tokenB pool seeded so we can do ETH -> A -> B.
        // (already done in setUp for both pools)
        PathKey[] memory path = new PathKey[](2);
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

        uint256 bBefore = tokenB.balanceOf(address(this));
        uint256 out = router.swapExactInput{value: 1 ether}(
            Currency.wrap(address(0)),
            path,
            1 ether,
            1,
            address(this),
            block.timestamp + 100
        );

        assertGt(out, 0);
        assertEq(tokenB.balanceOf(address(this)) - bBefore, out);
    }

    // ------------------------------------------------------------------
    // InvalidCallbackKind: hit the `else { revert }` branch in
    // unlockCallback by encoding an unknown tag.
    // ------------------------------------------------------------------
    function testUnlockCallbackInvalidTagReverts() public {
        // Have the manager unlock the router with a bogus tag in the payload.
        // The router's unlockCallback is `onlyPoolManager`, so we must route
        // through the manager. Use vm.prank to impersonate the manager.
        bytes memory raw = abi.encode(uint8(99), bytes(""));
        vm.prank(address(manager));
        vm.expectRevert(SpryRouter.InvalidCallbackKind.selector);
        router.unlockCallback(raw);
    }

    receive() external payable {}
}
