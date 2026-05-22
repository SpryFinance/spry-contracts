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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {InvariantHandler} from "./InvariantHandler.sol";

/// @notice Top-level invariant suite for the V4 surface. Asserts cross-state
///         properties that must hold after any sequence of handler-driven
///         random operations (swap/add/remove across multiple actors).
///         LP positions are tracked per-owner by V4 itself (per-owner salt
///         on LPHelper), so the invariants here focus on the V4-level
///         accounting: pool liquidity = sum of per-owner positions, and
///         the manager stays solvent while any liquidity is present.
contract Invariants is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    SpryHook public hook;
    SpryRouter public router;
    LPHelper public lp;
    ERC20Mock public token0;
    ERC20Mock public token1;
    PoolKey public key;
    InvariantHandler public handler;

    address internal seeder;
    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        seeder = address(this);

        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

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

        // Seed the pool with initial liquidity from the test contract so the
        // very first swap call in the handler has something to swap against.
        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        lp.addLiquidity(key, 1e22, 1e22, seeder);

        handler = new InvariantHandler(manager, router, lp, key, token0, token1);

        // Restrict invariant fuzzer to only the handler's external functions.
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = InvariantHandler.swapExactIn.selector;
        selectors[1] = InvariantHandler.addLiquidity.selector;
        selectors[2] = InvariantHandler.removeLiquidity.selector;
        selectors[3] = InvariantHandler.rollBlocks.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------

    /// @notice The pool's in-range liquidity equals the sum of every owner's
    ///         per-owner V4 position. The seeder (this contract) plus every
    ///         handler actor must account for the full pool depth.
    function invariant_poolLiquidityEqualsSumOfPositions() public view {
        uint128 poolLiq = manager.getLiquidity(key.toId());
        uint256 sum = uint256(lp.positionLiquidity(key, seeder));
        sum += handler.actorPositionSum();
        assertEq(uint256(poolLiq), sum, "pool liquidity != sum of per-owner positions");
    }

    /// @notice PoolManager must hold at least the unclaimed token amounts
    ///         that back the current position. We check it stays solvent in
    ///         the simple sense: balance0 > 0 AND balance1 > 0 as long as
    ///         there is any liquidity.
    function invariant_managerSolventWhileLiquidityLives() public view {
        uint128 liq = manager.getLiquidity(key.toId());
        if (liq == 0) return;
        assertGt(token0.balanceOf(address(manager)), 0, "manager drained of token0 with liquidity present");
        assertGt(token1.balanceOf(address(manager)), 0, "manager drained of token1 with liquidity present");
    }

    /// @notice The per-pool `signedCum` must remain in a realistic
    ///         magnitude bound under any handler-driven sequence. The
    ///         hook saturates to `int128` (≈1.7e38), but the curve only
    ///         produces |delta| ≤ 1000 per swap (per-mille reserve
    ///         shift), and a one-block window collects at most a few
    ///         hundred swaps under the campaign. `1e9` is several orders
    ///         of magnitude above any realistic accumulation and several
    ///         dozen orders below the saturation threshold — a failure
    ///         here would mean either a delta-computation bug or an
    ///         overflow path in the cumulative accumulation, both of
    ///         which would corrupt fee dispatch.
    function invariant_cumulativeBoundedRealistically() public view {
        (, int128 signedCum) = hook.poolWindow(key.toId());
        uint256 abs = signedCum >= 0
            ? uint256(int256(signedCum))
            : uint256(-int256(signedCum));
        assertLt(abs, 1_000_000_000, "|signedCum| escaped realistic bound");
    }

    /// @notice The lazy-reset logic must never write a window-start past
    ///         the current block. `windowStart` is set to `uint64(block.number)`
    ///         inside `beforeSwap`, so a value greater than the current
    ///         block would indicate either a state-corruption bug or a
    ///         miswire in how the reset branch is taken.
    function invariant_windowStartNeverInFuture() public view {
        (uint64 windowStart, ) = hook.poolWindow(key.toId());
        assertLe(uint256(windowStart), block.number, "windowStart > block.number");
    }

    receive() external payable {}
}
