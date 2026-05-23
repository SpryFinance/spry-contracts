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
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {InvariantHandler} from "./InvariantHandler.sol";

/// @title TwoPoolInvariants
/// @notice Two independent pools share the same `PoolManager`, `SpryHook`,
///         `SpryRouter`, and `LPHelper`. Each pool gets its own
///         `InvariantHandler` instance, and the campaign fuzzer
///         interleaves random operations across both. Every invariant
///         then asserts the existing single-pool properties on EACH
///         pool independently — so any cross-pool state-bleed (e.g.
///         the hook accidentally keying `_poolWindow` by something
///         other than the PoolId) would surface as a violation on the
///         "innocent" pool after activity on the "noisy" one.
///
///         The four pinned invariants per pool:
///           - liquidity matches the sum of per-owner positions
///           - manager stays solvent while liquidity is present
///           - |signedCum| stays within realistic magnitude bounds
///           - windowStart never lands in the future
contract TwoPoolInvariants is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    SpryHook public hook;
    SpryRouter public router;
    LPHelper public lp;

    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    ERC20Mock public tokenC;

    PoolKey public keyAB;
    PoolKey public keyBC;

    InvariantHandler public handlerAB;
    InvariantHandler public handlerBC;

    address internal seeder;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function setUp() public {
        seeder = address(this);

        manager = IPoolManager(new PoolManager(address(this)));
        router  = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp      = new LPHelper(manager);

        // Three address-sorted tokens forming two pools (AB and BC).
        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        ERC20Mock c = new ERC20Mock();
        (tokenA, tokenB, tokenC) = _sortThree(a, b, c);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        keyAB = _erc20Key(tokenA, tokenB);
        keyBC = _erc20Key(tokenB, tokenC);
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);

        // Seed both pools so the fuzzer has something to swap against.
        deal(address(tokenA), seeder, 1e30);
        deal(address(tokenB), seeder, 1e30);
        deal(address(tokenC), seeder, 1e30);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);

        lp.addLiquidity(keyAB, 1e22, 1e22, seeder);
        lp.addLiquidity(keyBC, 1e22, 1e22, seeder);

        // One handler per pool. Each handler shares actors (alice/bob/
        // carol via makeAddr) — the constructor `deal`s + approves
        // them independently, which is idempotent for fresh accounts.
        handlerAB = new InvariantHandler(manager, router, lp, keyAB, tokenA, tokenB);
        handlerBC = new InvariantHandler(manager, router, lp, keyBC, tokenB, tokenC);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = InvariantHandler.swapExactIn.selector;
        selectors[1] = InvariantHandler.addLiquidity.selector;
        selectors[2] = InvariantHandler.removeLiquidity.selector;
        selectors[3] = InvariantHandler.rollBlocks.selector;
        targetSelector(FuzzSelector({addr: address(handlerAB), selectors: selectors}));
        targetSelector(FuzzSelector({addr: address(handlerBC), selectors: selectors}));
        targetContract(address(handlerAB));
        targetContract(address(handlerBC));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

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

    function _checkLiquidityMatchesPositions(
        PoolKey memory key,
        InvariantHandler handler
    ) internal view {
        uint128 poolLiq = manager.getLiquidity(key.toId());
        uint256 sum = uint256(lp.positionLiquidity(key, seeder));
        sum += handler.actorPositionSum();
        assertEq(uint256(poolLiq), sum, "pool liquidity != sum of per-owner positions");
    }

    function _checkManagerSolvent(PoolKey memory key) internal view {
        uint128 liq = manager.getLiquidity(key.toId());
        if (liq == 0) return;
        ERC20Mock t0 = ERC20Mock(Currency.unwrap(key.currency0));
        ERC20Mock t1 = ERC20Mock(Currency.unwrap(key.currency1));
        assertGt(t0.balanceOf(address(manager)), 0, "manager drained of token0");
        assertGt(t1.balanceOf(address(manager)), 0, "manager drained of token1");
    }

    function _checkCumBounded(PoolKey memory key) internal view {
        (, int128 signedCum) = hook.poolWindow(key.toId());
        uint256 abs = signedCum >= 0
            ? uint256(int256(signedCum))
            : uint256(-int256(signedCum));
        assertLt(abs, 1_000_000_000, "|signedCum| escaped realistic bound");
    }

    function _checkWindowStartValid(PoolKey memory key) internal view {
        (uint64 windowStart, ) = hook.poolWindow(key.toId());
        assertLe(uint256(windowStart), block.number, "windowStart > block.number");
    }

    // ---------------------------------------------------------------------
    // Invariants — each one asserts the property on BOTH pools.
    // ---------------------------------------------------------------------

    function invariant_bothPoolsLiquidityMatchesPositions() public view {
        _checkLiquidityMatchesPositions(keyAB, handlerAB);
        _checkLiquidityMatchesPositions(keyBC, handlerBC);
    }

    function invariant_bothPoolsManagerSolvent() public view {
        _checkManagerSolvent(keyAB);
        _checkManagerSolvent(keyBC);
    }

    function invariant_bothPoolsCumBounded() public view {
        _checkCumBounded(keyAB);
        _checkCumBounded(keyBC);
    }

    function invariant_bothPoolsWindowStartValid() public view {
        _checkWindowStartValid(keyAB);
        _checkWindowStartValid(keyBC);
    }

    receive() external payable {}
}
