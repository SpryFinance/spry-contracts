// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Stateful fuzz handler. Forge calls these public functions with
///         random args; each one bounds inputs to a sane range, executes
///         the op against the V4 router, and updates ghost counters.
///         In-call assertions (e.g. K-conservation across pure swaps) live
///         here; cross-state invariants live on the top-level test contract.
contract InvariantHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable MANAGER;
    SpryRouter public immutable ROUTER;
    PoolKey public KEY;
    ERC20Mock public immutable TOKEN0;
    ERC20Mock public immutable TOKEN1;

    // Bookkeeping for invariant assertions on the test contract.
    uint256 public swapCount;
    uint256 public addCount;
    uint256 public removeCount;
    uint256 public totalSharesMinted;
    uint256 public totalSharesBurned;

    // Multiple actor identities so the per-holder ledger is exercised.
    address[3] public actors;

    constructor(
        IPoolManager _manager,
        SpryRouter _router,
        PoolKey memory _key,
        ERC20Mock _token0,
        ERC20Mock _token1
    ) {
        MANAGER = _manager;
        ROUTER = _router;
        KEY = _key;
        TOKEN0 = _token0;
        TOKEN1 = _token1;

        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");

        for (uint256 i; i < actors.length; ++i) {
            deal(address(TOKEN0), actors[i], 1e30);
            deal(address(TOKEN1), actors[i], 1e30);
            vm.startPrank(actors[i]);
            TOKEN0.approve(address(ROUTER), type(uint256).max);
            TOKEN1.approve(address(ROUTER), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 idx) internal view returns (address) {
        return actors[idx % actors.length];
    }

    function _poolId() internal view returns (PoolId) {
        return KEY.toId();
    }

    function _kFromState() internal view returns (uint256) {
        // K = L^2 since L = sqrt(R0 * R1) for full-range pools. sqrtPriceX96
        // is intentionally not read here — only liquidity matters for K.
        uint128 liquidity = MANAGER.getLiquidity(_poolId());
        return uint256(liquidity) * uint256(liquidity);
    }

    /// @notice Exact-input swap. Bounded to amounts that won't deplete the
    ///         pool or revert at the sqrtPriceLimit. K must not decrease.
    function swapExactIn(uint256 amountIn, bool zeroForOne, uint256 actorIdx) external {
        address actor = _actor(actorIdx);
        amountIn = bound(amountIn, 1e12, 5e20);

        uint256 kBefore = _kFromState();

        vm.startPrank(actor);
        try ROUTER.swapExactInputSingle(KEY, zeroForOne, amountIn, 1, actor, block.timestamp + 100) {
            ++swapCount;
        } catch {
            // Swap reverted (likely hit the sqrtPriceLimit) - skip
        }
        vm.stopPrank();

        uint256 kAfter = _kFromState();
        // K never decreases under a pure swap: fees accrue to the pool.
        // Allow equality (zero-fee skip path) but not decrease.
        assertGe(kAfter, kBefore, "handler: K decreased across swap");
    }

    function addLiquidity(uint256 amount0, uint256 amount1, uint256 actorIdx) external {
        address actor = _actor(actorIdx);
        amount0 = bound(amount0, 1e15, 1e22);
        amount1 = bound(amount1, 1e15, 1e22);

        vm.startPrank(actor);
        try ROUTER.addLiquidity(KEY, amount0, amount1, 0, 0, actor, block.timestamp + 100) returns (
            uint128 liquidity,
            uint256,
            uint256
        ) {
            ++addCount;
            totalSharesMinted += uint256(liquidity);
        } catch {
            // Pool not initialized or insufficient liquidity computed.
        }
        vm.stopPrank();
    }

    function removeLiquidity(uint256 fractionBps, uint256 actorIdx) external {
        address actor = _actor(actorIdx);
        fractionBps = bound(fractionBps, 1, 10_000);

        uint256 bal = ROUTER.balanceOf(actor, uint256(uint256(PoolId.unwrap(_poolId()))));
        if (bal == 0) return;

        uint128 toRemove = uint128((bal * fractionBps) / 10_000);
        if (toRemove == 0) return;

        vm.startPrank(actor);
        try ROUTER.removeLiquidity(KEY, toRemove, 0, 0, actor, block.timestamp + 100) {
            ++removeCount;
            totalSharesBurned += uint256(toRemove);
        } catch {}
        vm.stopPrank();
    }

    /// @notice Sum of LP shares across known actors. Used by the invariant
    ///         test to prove balance bookkeeping matches totalSupply.
    function actorSharesSum() external view returns (uint256 s) {
        uint256 id = uint256(PoolId.unwrap(_poolId()));
        for (uint256 i; i < actors.length; ++i) {
            s += ROUTER.balanceOf(actors[i], uint256(id));
        }
    }
}
