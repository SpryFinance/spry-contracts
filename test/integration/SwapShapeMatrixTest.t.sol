// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title SwapShapeMatrixTest
/// @notice Fills the remaining gaps in the router's swap-shape coverage:
///         ERC20-to-native-ETH single-hop, native-ETH-as-intermediate
///         multi-hop, recipient distinct from caller, accidental-msg.value
///         refund, multi-hop exact-output happy + slippage, and a couple of
///         pathological inputs (zero amount, cycle path).
contract SwapShapeMatrixTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    ERC20Mock internal tokenC;

    PoolKey internal keyAB;     // ERC20 pair
    PoolKey internal keyEthA;   // (native ETH, tokenA)  — currency0 = ETH
    PoolKey internal keyEthB;   // (native ETH, tokenB)
    PoolKey internal keyBC;     // ERC20 pair

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant SEED = 1e22;

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

        // Make three tokens whose addresses are all greater than address(0)
        // (which they will be — EVM contract addresses are never zero).
        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        ERC20Mock c = new ERC20Mock();
        (tokenA, tokenB, tokenC) = _sortThree(a, b, c);

        // Fund the test contract + actors.
        _fund(address(this));
        _fund(alice);
        _fund(bob);

        keyAB = _erc20Key(tokenA, tokenB);
        keyBC = _erc20Key(tokenB, tokenC);
        keyEthA = _ethKey(tokenA);
        keyEthB = _ethKey(tokenB);

        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);
        manager.initialize(keyEthA, SQRT_PRICE_1_1);
        manager.initialize(keyEthB, SQRT_PRICE_1_1);

        lp.addLiquidity(keyAB, SEED, SEED, address(this));
        lp.addLiquidity(keyBC, SEED, SEED, address(this));
        lp.addLiquidity{value: 50 ether}(keyEthA, 50 ether, 50 ether, address(this));
        lp.addLiquidity{value: 50 ether}(keyEthB, 50 ether, 50 ether, address(this));
    }

    function _fund(address who) internal {
        deal(address(tokenA), who, 1e30);
        deal(address(tokenB), who, 1e30);
        deal(address(tokenC), who, 1e30);
        deal(who, 1000 ether);
        vm.startPrank(who);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);
        vm.stopPrank();
    }

    function _sortThree(ERC20Mock a, ERC20Mock b, ERC20Mock c)
        internal
        pure
        returns (ERC20Mock, ERC20Mock, ERC20Mock)
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

    function _ethKey(ERC20Mock t) internal view returns (PoolKey memory) {
        // currency0 must be address(0) since it sorts below every real address.
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(t)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    // ---------------------------------------------------------------------
    // 1. ERC20 -> native ETH single-hop (ETH as OUTPUT)
    // ---------------------------------------------------------------------
    function testExactInputERC20ToETHDelivers() public {
        uint256 ethBefore = address(this).balance;
        uint256 tokABefore = tokenA.balanceOf(address(this));

        // zeroForOne = false: tokenA (currency1) in, ETH (currency0) out.
        uint256 ethReceived = router.swapExactInputSingle(
            keyEthA,
            false,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");

        assertGt(ethReceived, 0, "received some ETH");
        assertEq(address(this).balance - ethBefore, ethReceived, "ETH credited to caller");
        assertEq(tokABefore - tokenA.balanceOf(address(this)), 1e18, "tokenA debited exactly");
    }

    // ---------------------------------------------------------------------
    // 2. Multi-hop with native ETH as an intermediate currency
    //    (A -> ETH -> B)
    // ---------------------------------------------------------------------
    function testMultiHopETHIntermediate() public {
        uint256 aBefore = tokenA.balanceOf(address(this));
        uint256 bBefore = tokenB.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(0)),
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

        uint256 out = router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );

        assertGt(out, 0);
        assertEq(aBefore - tokenA.balanceOf(address(this)), 1e18, "tokenA debited exactly");
        assertEq(tokenB.balanceOf(address(this)) - bBefore, out, "tokenB credited exactly");
        // ETH was used only as a transit currency inside the unlock callback.
        assertEq(address(this).balance, ethBefore, "ETH transit balance unchanged");
    }

    // ---------------------------------------------------------------------
    // 3. Recipient distinct from msg.sender — aggregator pattern.
    // ---------------------------------------------------------------------
    function testRecipientDistinctFromSender() public {
        uint256 aliceABefore = tokenA.balanceOf(alice);
        uint256 bobBBefore = tokenB.balanceOf(bob);

        vm.prank(alice);
        uint256 out = router.swapExactInputSingle(
            keyAB,
            true,                  // tokenA -> tokenB
            1e18,
            1,
            bob,                   // recipient = bob, not alice
            block.timestamp + 100
        ,
        "");

        assertGt(out, 0);
        assertEq(aliceABefore - tokenA.balanceOf(alice), 1e18, "alice paid the input");
        assertEq(tokenB.balanceOf(bob) - bobBBefore, out, "bob received the output");
    }

    // ---------------------------------------------------------------------
    // 4. Zero-amount input must revert at the pool layer.
    // ---------------------------------------------------------------------
    function testZeroAmountInputReverts() public {
        vm.expectRevert();
        router.swapExactInputSingle(
            keyAB,
            true,
            0,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");
    }

    // ---------------------------------------------------------------------
    // 5. Demanding more output than the pool can supply must revert.
    // ---------------------------------------------------------------------
    function testExactOutputExceedingReservesReverts() public {
        vm.expectRevert();
        router.swapExactOutputSingle(
            keyAB,
            true,
            type(uint128).max,     // unreachable output
            type(uint256).max,
            address(this),
            block.timestamp + 100
        ,
        "");
    }

    // ---------------------------------------------------------------------
    // 6. msg.value sent on a non-ETH pool swap is refunded to msg.sender,
    //    NOT silently kept on the router.
    // ---------------------------------------------------------------------
    function testMsgValueOnNonETHPoolRefunded() public {
        uint256 ethBefore = address(this).balance;

        router.swapExactInputSingle{value: 1 ether}(
            keyAB,                 // ERC20-only pool — never touches msg.value
            true,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");

        // Caller paid no ETH; full 1 ether refund came back.
        assertEq(address(this).balance, ethBefore, "ETH fully refunded to caller");
        assertEq(address(router).balance, 0, "router holds no stray ETH after the call");
    }

    // ---------------------------------------------------------------------
    // 7. A cycle path A -> B -> A still completes but with strict loss.
    //    Documents the semantics: the router does not detect cycles, so
    //    the user pays two fees and ends up with less of A than they put in.
    // ---------------------------------------------------------------------
    function testCyclePathLosesValueButCompletes() public {
        uint256 aBefore = tokenA.balanceOf(address(this));

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

        uint256 out = router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );

        // Output is in tokenA again; user paid two hops of fees so they
        // end up with strictly less than they put in.
        assertGt(out, 0, "round-trip cycle completes");
        assertLt(out, 1e18, "user pays two-hop fees and ends up short");
        assertEq(aBefore - tokenA.balanceOf(address(this)), 1e18 - out, "net loss matches fee drag");
    }

    // ---------------------------------------------------------------------
    // 8. Multi-hop exact-output happy path.
    //    V4-style encoding: `currencyOut` is the user's final output;
    //    `path[0].intermediateCurrency` is the user's input, and each
    //    subsequent element is the intermediate one hop further toward
    //    the output. For A -> B -> C with exact C, path = [{A}, {B}].
    // ---------------------------------------------------------------------
    function testMultiHopExactOutputDelivers() public {
        uint256 aBefore = tokenA.balanceOf(address(this));
        uint256 cBefore = tokenC.balanceOf(address(this));
        uint256 bBefore = tokenB.balanceOf(address(this));
        uint256 wanted = 1e18;

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

        uint256 amountIn = router.swapExactOutput(
            Currency.wrap(address(tokenC)),
            path,
            wanted,
            type(uint256).max,
            address(this),
            block.timestamp + 100
        );

        assertGt(amountIn, 0, "router reports a non-zero input");
        assertEq(aBefore - tokenA.balanceOf(address(this)), amountIn, "tokenA debited exactly amountIn");
        assertEq(tokenC.balanceOf(address(this)) - cBefore, wanted, "tokenC delivered exactly amountOut");
        assertEq(tokenB.balanceOf(address(this)), bBefore, "intermediate tokenB net-zero");
    }

    // ---------------------------------------------------------------------
    // 9. Multi-hop exact-output reverts on amountInMax violation.
    // ---------------------------------------------------------------------
    function testMultiHopExactOutputAmountInMaxReverts() public {
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

        vm.expectRevert(SpryRouter.ExcessiveInput.selector);
        router.swapExactOutput(
            Currency.wrap(address(tokenC)),
            path,
            1e18,
            1,                     // amountInMax impossibly low
            address(this),
            block.timestamp + 100
        );
    }

    // ---------------------------------------------------------------------
    // 10. Multi-hop exact-output with empty path reverts.
    // ---------------------------------------------------------------------
    function testMultiHopExactOutputEmptyPathReverts() public {
        PathKey[] memory path = new PathKey[](0);
        vm.expectRevert(SpryRouter.EmptyPath.selector);
        router.swapExactOutput(
            Currency.wrap(address(tokenC)),
            path,
            1e18,
            type(uint256).max,
            address(this),
            block.timestamp + 100
        );
    }

    // ---------------------------------------------------------------------
    // 11. Overpaying ETH on an ETH-input swap refunds only the excess,
    //     not any pre-existing balance on the router (snapshot pattern).
    // ---------------------------------------------------------------------
    function testExactInputEthRefundOnlyTheExcess() public {
        // Pre-stash some ETH on the router from a third party (alice).
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 5 ether}("");
        assertTrue(ok, "third-party prefund succeeded");
        assertEq(address(router).balance, 5 ether);

        uint256 ethBefore = address(this).balance;
        // Swap 1 ETH for tokenA but send 3 ETH. We expect a 2 ETH refund;
        // the 5 ETH alice pre-stashed must NOT be touched.
        router.swapExactInputSingle{value: 3 ether}(
            keyEthA,
            true,
            1 ether,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");

        // We paid 1 ETH; router still holds alice's 5 ETH stash exactly.
        assertEq(ethBefore - address(this).balance, 1 ether, "paid exactly 1 ETH");
        assertEq(address(router).balance, 5 ether, "alice's stash intact");
    }

    receive() external payable {}
}
