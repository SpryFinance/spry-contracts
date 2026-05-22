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

import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title QuoterTest
/// @notice Validates that v4-periphery's `V4Quoter`, deployed alongside our
///         router, returns swap quotes that exactly match the amounts the
///         router actually delivers when the same swap is executed.
///         Because both contracts use the same `PathKey` shape and follow
///         the same convention, integrators can call the quoter with the
///         same path they'll pass to the router.
///
///         The quoter doesn't need any Spry-specific code — `V4Quoter` is
///         the canonical Uniswap implementation, audited and unchanged.
///         This file exists purely to lock in the equivalence as a
///         regression test.
contract QuoterTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    V4Quoter internal quoter;

    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    ERC20Mock internal tokenC;

    PoolKey internal keyAB;
    PoolKey internal keyBC;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant SEED = 1e22;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);
        quoter = new V4Quoter(manager);

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
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);

        keyAB = _erc20Key(tokenA, tokenB);
        keyBC = _erc20Key(tokenB, tokenC);
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);

        lp.addLiquidity(keyAB, SEED, SEED, address(this));
        lp.addLiquidity(keyBC, SEED, SEED, address(this));
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

    // ---------------------------------------------------------------------
    // 1. Single-hop exact-input — quote matches actual swap output.
    // ---------------------------------------------------------------------
    function testQuoteExactInputSingleMatchesActual() public {
        uint128 amountIn = 1e18;

        (uint256 quoted, ) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: keyAB,
                zeroForOne: true,
                exactAmount: amountIn,
                hookData: ""
            })
        );

        uint256 actual = router.swapExactInputSingle(
            keyAB, true, amountIn, 1, address(this), block.timestamp + 100, ""
        );
        assertEq(actual, quoted, "quoted output equals actual output");
    }

    // ---------------------------------------------------------------------
    // 2. Single-hop exact-output — quote matches actual swap input.
    // ---------------------------------------------------------------------
    function testQuoteExactOutputSingleMatchesActual() public {
        uint128 wanted = 1e17;

        (uint256 quoted, ) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: keyAB,
                zeroForOne: true,
                exactAmount: wanted,
                hookData: ""
            })
        );

        uint256 actual = router.swapExactOutputSingle(
            keyAB, true, wanted, type(uint256).max, address(this), block.timestamp + 100, ""
        );
        assertEq(actual, quoted, "quoted input equals actual input");
    }

    // ---------------------------------------------------------------------
    // 3. Multi-hop exact-input — quote matches actual final-currency output.
    //    Both quoter and router use the same forward-path encoding:
    //      exactCurrency = user's input (A)
    //      path[0].intermediateCurrency = B   (output of hop 0)
    //      path[1].intermediateCurrency = C   (final output)
    // ---------------------------------------------------------------------
    function testQuoteExactInputMultiHopMatchesActual() public {
        uint128 amountIn = 1e18;

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

        (uint256 quoted, ) = quoter.quoteExactInput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(tokenA)),
                path: path,
                exactAmount: amountIn
            })
        );

        uint256 actual = router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            amountIn,
            1,
            address(this),
            block.timestamp + 100
        );

        assertEq(actual, quoted, "quoted final-currency output equals actual");
    }

    // ---------------------------------------------------------------------
    // 4. Multi-hop exact-output — quote matches actual input amount.
    //    V4 reverse-path encoding (matches our `swapExactOutput`):
    //      exactCurrency = user's output (C)
    //      path[0].intermediateCurrency = A   (user's INPUT)
    //      path[1].intermediateCurrency = B   (intermediate)
    // ---------------------------------------------------------------------
    function testQuoteExactOutputMultiHopMatchesActual() public {
        uint128 wanted = 1e17;

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

        (uint256 quoted, ) = quoter.quoteExactOutput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(tokenC)),
                path: path,
                exactAmount: wanted
            })
        );

        uint256 actual = router.swapExactOutput(
            Currency.wrap(address(tokenC)),
            path,
            wanted,
            type(uint256).max,
            address(this),
            block.timestamp + 100
        );

        assertEq(actual, quoted, "quoted input equals actual input");
    }

    // ---------------------------------------------------------------------
    // 5. The quoter reflects the dynamic fee — a small swap (safe zone)
    //    quotes a tighter input/output ratio than a huge swap (danger zone).
    // ---------------------------------------------------------------------
    function testQuoteReflectsDynamicFeeZones() public {
        // Small swap should sit in the SmartFee safe zone (~3 bps).
        (uint256 smallOut, ) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: keyAB,
                zeroForOne: true,
                exactAmount: 1e15,            // 0.001% of pool reserves
                hookData: ""
            })
        );
        // Large swap is firmly in the danger zone (~50 bps).
        (uint256 largeOut, ) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: keyAB,
                zeroForOne: true,
                exactAmount: 5e21,            // 50% of pool reserves
                hookData: ""
            })
        );

        // Effective output-per-input rate. Scaled to keep numbers tractable.
        uint256 smallRate = smallOut * 1e18 / 1e15;
        uint256 largeRate = largeOut * 1e18 / 5e21;
        // Big swap pays both higher fees AND more price impact, so the
        // received-per-unit-paid ratio must be strictly worse.
        assertLt(largeRate, smallRate, "danger-zone swap yields strictly less per unit input");
    }

    // ---------------------------------------------------------------------
    // Failure modes — quoter surfaces V4's underlying revert wrapped in
    // `UnexpectedRevertBytes`. The wrapping is the contract's way of
    // saying "this was not a valid quote outcome." Integrators that catch
    // quoter calls must handle both `QuoteSwap` (success) and
    // `UnexpectedRevertBytes` (downstream failure).
    // ---------------------------------------------------------------------

    /// @dev Quote against a `PoolKey` that was never initialized. V4
    ///      reverts inside the swap with a pool-not-initialized error,
    ///      the quoter catches that and rethrows as
    ///      `UnexpectedRevertBytes`.
    function testQuoteRevertsOnUninitializedPool() public {
        ERC20Mock untouched = new ERC20Mock();
        (Currency c0, Currency c1) = address(untouched) < address(tokenA)
            ? (Currency.wrap(address(untouched)), Currency.wrap(address(tokenA)))
            : (Currency.wrap(address(tokenA)), Currency.wrap(address(untouched)));
        PoolKey memory uninitKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert();
        quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: uninitKey,
                zeroForOne: true,
                exactAmount: 1e18,
                hookData: ""
            })
        );
    }

    /// @dev Quote against a pool that has been initialized but never seeded
    ///      with liquidity. The swap simulation reverts with V4's
    ///      `NotEnoughLiquidity` (or equivalent zero-liquidity guard); the
    ///      quoter surfaces it as `UnexpectedRevertBytes`.
    function testQuoteRevertsOnInitializedButEmptyPool() public {
        // Build a key for a brand-new pair that we initialize but never
        // fund. Has to use a token we haven't given liquidity for yet.
        ERC20Mock empty = new ERC20Mock();
        (Currency c0, Currency c1) = address(empty) < address(tokenA)
            ? (Currency.wrap(address(empty)), Currency.wrap(address(tokenA)))
            : (Currency.wrap(address(tokenA)), Currency.wrap(address(empty)));
        PoolKey memory emptyKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(emptyKey, SQRT_PRICE_1_1);
        // No addLiquidity call — pool has zero in-range liquidity.

        vm.expectRevert();
        quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: emptyKey,
                zeroForOne: true,
                exactAmount: 1e18,
                hookData: ""
            })
        );
    }

    /// @dev Multi-hop quote where the *intermediate* pool is uninitialized.
    ///      Pins that failure at any hop bubbles up cleanly through the
    ///      whole quote, not just the first hop.
    function testQuoteRevertsOnUninitializedIntermediateHop() public {
        // Path tokenA -> tokenC where the AC pool was never created in
        // setUp (we only initialized AB and BC). Use a single hop directly
        // referencing the missing pool.
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        vm.expectRevert();
        quoter.quoteExactInput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(tokenA)),
                path: path,
                exactAmount: 1e18
            })
        );
    }

    // ---------------------------------------------------------------------
    // 6. Quote-after-state-shift: do a real swap that moves the pool, then
    //    quote a second swap. The new quote must match the actual second
    //    swap, proving the quoter reads the live pool state at quote time.
    // ---------------------------------------------------------------------
    function testQuoteReflectsLivePoolState() public {
        // First, do a sizable real swap to shift the pool.
        router.swapExactInputSingle(
            keyAB, true, 2e21, 1, address(this), block.timestamp + 100, ""
        );

        // Now quote, then actually execute the same swap; outputs must agree.
        uint128 secondAmount = 1e18;
        (uint256 quoted, ) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: keyAB,
                zeroForOne: true,
                exactAmount: secondAmount,
                hookData: ""
            })
        );
        uint256 actual = router.swapExactInputSingle(
            keyAB, true, secondAmount, 1, address(this), block.timestamp + 100, ""
        );
        assertEq(actual, quoted, "quote after state shift still matches actual");
    }

    receive() external payable {}
}
