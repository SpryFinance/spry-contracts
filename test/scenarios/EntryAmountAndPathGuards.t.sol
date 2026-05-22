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

/// @title EntryAmountAndPathGuardsTest
/// @notice Pins two SpryRouter input guards that surface silent footguns
///         as clear reverts:
///
///         (1) Amount-bound guard. Any swap amount > type(int256).max gets
///         bit-reinterpreted on the `int256(uint256)` cast inside
///         SwapParams.amountSpecified. For exactIn that flips the sign
///         back to positive (i.e. exactOut); for the exact boundary value
///         type(int256).min the negation overflows. Unreachable in
///         practice (~5.79e76 tokens), but the router rejects oversized
///         inputs at the entry point so the semantic flip cannot occur.
///
///         (2) Path repeated-currency guard. A multi-hop path whose i-th
///         hop has `path[i].intermediateCurrency == previous-currency`
///         would form a PoolKey with `currency0 == currency1`. V4 cannot
///         initialize such a pool, so the call would revert inside the
///         swap simulation with an obscure pool-not-initialized error.
///         The router rejects the misconfiguration up front with
///         `InvalidPath`.
contract EntryAmountAndPathGuardsTest is Test {
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

    // -----------------------------------------------------------------
    // N3 — amount must fit in int256 (i.e. high bit must be clear)
    // -----------------------------------------------------------------
    /// The boundary value is `uint256(type(int256).max) + 1 == 2^255`.
    /// Anything at or above that has its sign bit set and would flip
    /// the int256 reinterpretation on the SwapParams.amountSpecified path.

    function _aboveInt256Max() internal pure returns (uint256) {
        // 2^255 — first value whose int256 reinterpretation is negative.
        return uint256(type(int256).max) + 1;
    }

    function testSwapExactInputSingleRejectsHugeAmount() public {
        vm.expectRevert(SpryRouter.AmountTooLarge.selector);
        router.swapExactInputSingle(
            keyAB, true, _aboveInt256Max(), 0, address(this), block.timestamp + 100, ""
        );
    }

    function testSwapExactOutputSingleRejectsHugeAmount() public {
        vm.expectRevert(SpryRouter.AmountTooLarge.selector);
        router.swapExactOutputSingle(
            keyAB, true, _aboveInt256Max(), type(uint256).max, address(this), block.timestamp + 100, ""
        );
    }

    function testSwapExactInputSingleViaPermit2RejectsHugeAmount() public {
        vm.expectRevert(SpryRouter.AmountTooLarge.selector);
        router.swapExactInputSingleViaPermit2(
            keyAB, true, _aboveInt256Max(), 0, address(this), block.timestamp + 100, ""
        );
    }

    function testSwapExactOutputSingleViaPermit2RejectsHugeAmount() public {
        vm.expectRevert(SpryRouter.AmountTooLarge.selector);
        router.swapExactOutputSingleViaPermit2(
            keyAB, true, _aboveInt256Max(), type(uint256).max, address(this), block.timestamp + 100, ""
        );
    }

    function testSwapExactInputMultiHopRejectsHugeAmount() public {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        vm.expectRevert(SpryRouter.AmountTooLarge.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)), path, _aboveInt256Max(), 0, address(this), block.timestamp + 100
        );
    }

    function testSwapExactOutputMultiHopRejectsHugeAmount() public {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        vm.expectRevert(SpryRouter.AmountTooLarge.selector);
        router.swapExactOutput(
            Currency.wrap(address(tokenB)),
            path,
            _aboveInt256Max(),
            type(uint256).max,
            address(this),
            block.timestamp + 100
        );
    }

    /// @dev Sanity: the largest *valid* amount (exactly type(int256).max)
    ///      passes the guard. The pool itself will revert deep inside V4
    ///      because reserves are nowhere near that, but it must NOT
    ///      revert with AmountTooLarge.
    function testBoundaryValueDoesNotTripGuard() public {
        // We don't try to actually execute the swap (V4 will revert on
        // tick math far before this value). Just confirm that hitting
        // the boundary value gets past `_assertAmountFitsInt256` and
        // fails downstream, not at the entry guard.
        try router.swapExactInputSingle(
            keyAB, true, uint256(type(int256).max), 0, address(this), block.timestamp + 100, ""
        ) {
            revert("expected downstream revert, not success");
        } catch (bytes memory reason) {
            // Whatever V4 reverts with, it must NOT be AmountTooLarge.
            bytes4 sel;
            if (reason.length >= 4) {
                assembly { sel := mload(add(reason, 0x20)) }
            }
            assertTrue(
                sel != SpryRouter.AmountTooLarge.selector,
                "boundary value should pass the entry guard"
            );
        }
    }

    // -----------------------------------------------------------------
    // N4 — multi-hop path with repeated currency must revert clearly
    // -----------------------------------------------------------------

    /// @dev Forward path A -> B -> B (last hop has intermediate == prior
    ///      output). Triggers `currentIn == currentOut` on the second
    ///      iteration of `_executeMultiExactInput`.
    function testMultiHopExactInputRejectsRepeatedCurrency() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
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
        vm.expectRevert(SpryRouter.InvalidPath.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)), path, 1e18, 1, address(this), block.timestamp + 100
        );
    }

    /// @dev First-hop self-loop: currencyIn = A, path[0].intermediate = A.
    function testMultiHopExactInputRejectsFirstHopSelfLoop() public {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenA)),  // same as currencyIn below
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        vm.expectRevert(SpryRouter.InvalidPath.selector);
        router.swapExactInput(
            Currency.wrap(address(tokenA)), path, 1e18, 1, address(this), block.timestamp + 100
        );
    }

    /// @dev Reverse path for exactOutput: currencyOut = C and the last hop
    ///      (which the reverse walk processes first) has intermediateCurrency
    ///      = C. Triggers `currentIn == currentOut` in the very first
    ///      iteration of `_executeMultiExactOutput`.
    function testMultiHopExactOutputRejectsRepeatedCurrency() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),  // == currencyOut
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        vm.expectRevert(SpryRouter.InvalidPath.selector);
        router.swapExactOutput(
            Currency.wrap(address(tokenC)), path, 1e17, type(uint256).max, address(this), block.timestamp + 100
        );
    }

    receive() external payable {}
}
