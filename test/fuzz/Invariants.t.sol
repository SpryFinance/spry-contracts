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
import {HookMiner} from "../../contracts/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {InvariantHandler} from "./InvariantHandler.sol";

/// @notice Top-level invariant suite for the V4 surface. Asserts cross-state
///         properties that must hold after any sequence of handler-driven
///         random operations (swap/add/remove across multiple actors).
contract Invariants is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    SpryHook public hook;
    SpryRouter public router;
    ERC20Mock public token0;
    ERC20Mock public token1;
    PoolKey public key;
    InvariantHandler public handler;

    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager)
        );
        hook = new SpryHook{salt: salt}(manager);
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
        router.addLiquidity(key, 1e22, 1e22, 0, 0, address(this), block.timestamp + 100);

        handler = new InvariantHandler(manager, router, key, token0, token1);

        // Restrict invariant fuzzer to only the handler's external functions.
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = InvariantHandler.swapExactIn.selector;
        selectors[1] = InvariantHandler.addLiquidity.selector;
        selectors[2] = InvariantHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------

    /// @notice Every LP share the router issued must be backed by an equal
    ///         unit of liquidity in the router's full-range V4 position.
    function invariant_lpSharesMatchPositionLiquidity() public view {
        uint256 idBytes = uint256(PoolId.unwrap(key.toId()));
        uint256 routerSupply = router.totalSupply(uint256(idBytes));
        bytes32 positionId =
            keccak256(abi.encodePacked(address(router), TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), bytes32(0)));
        uint128 posLiq = manager.getPositionLiquidity(key.toId(), positionId);
        assertEq(routerSupply, uint256(posLiq), "totalSupply != V4 position liquidity");
    }

    /// @notice Sum of every actor's ERC6909 LP balance plus the setUp seeder
    ///         (this contract) must equal the router's totalSupply for the pool.
    function invariant_sharesAccountForFullSupply() public view {
        uint256 idBytes = uint256(PoolId.unwrap(key.toId()));
        uint256 sum = router.balanceOf(address(this), uint256(idBytes));
        sum += handler.actorSharesSum();
        assertEq(sum, router.totalSupply(uint256(idBytes)), "actor sum + seeder != totalSupply");
    }

    /// @notice The pool's reported in-range liquidity must equal the router's
    ///         total LP shares — only the router owns positions on this pool.
    function invariant_poolLiquidityEqualsRouterShares() public view {
        uint256 idBytes = uint256(PoolId.unwrap(key.toId()));
        uint128 poolLiq = manager.getLiquidity(key.toId());
        assertEq(uint256(poolLiq), router.totalSupply(uint256(idBytes)), "pool liquidity != router supply");
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

    receive() external payable {}
}
