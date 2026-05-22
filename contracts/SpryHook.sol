// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {SmartFeeLib} from "./libs/SmartFeeLib.sol";
import {SpryFeeParams} from "./libs/SpryFeeTypes.sol";

/// @title SpryHook
/// @notice V4 hook implementing Spry's tiered dynamic fee curve. On every
///         swap the hook reads the pool's current sqrtPriceX96 + liquidity,
///         looks up the pool's tier from `key.fee & 0xFF`, asks SmartFeeLib
///         what fee that tier's curve charges for this swap's delta, and
///         returns the result as the LP-fee override.
///
///         Five hardcoded tiers ship in v1, dispatched from the pool's
///         `tickSpacing` field (matching Uniswap V3's fee-tier convention):
///
///             tickSpacing    tier               pairs
///             ───────────────────────────────────────────────────────
///                   1        0  STABLE          USDC/USDT, stETH/ETH
///                  10        1  LIKE-ASSET      wstETH/ETH, USDC/USDC.e
///                  60        2  BLUE-CHIP       ETH/USDC, WBTC/ETH    ← v0 curve
///                 200        3  VOLATILE        ETH/SHIB, ETH/PEPE
///                1000        4  EXOTIC          low-cap / low-cap
///
///         Tiers 0,1,3,4 are introduced as bytecode immutables in a later
///         commit; this commit lands the dispatch infrastructure with
///         tier 2 (BLUE-CHIP) fully implemented and the others reverting
///         with `InvalidTier`.
///
///         Why `tickSpacing` and not `fee`: V4's `LPFeeLibrary.isDynamicFee`
///         uses EXACT equality (`self == DYNAMIC_FEE_FLAG`), so the lower
///         bits of `key.fee` cannot be repurposed without losing the
///         dynamic-fee dispatch. `tickSpacing` is a free natural choice
///         because (a) it's already part of the PoolKey identity, (b) it
///         conventionally encodes pool "tier" in V3, and (c) different
///         pools with the same tokens/hook but different tickSpacings are
///         distinct V4 pools.
///
/// @dev    The hook MUST be deployed at an address whose low 14 bits
///         match `permissionsFlags()` — use the included HookMiner. Other
///         IHooks entry points are implemented as no-ops for interface
///         completeness and only revert if called by anyone other than the
///         PoolManager.
contract SpryHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error InvalidTier();

    /// @notice Number of supported tiers. The dispatch supports indices
    ///         [0, TIER_COUNT). Indices outside this range revert with
    ///         `InvalidTier` from `beforeSwap`.
    uint8 public constant TIER_COUNT = 5;

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    /// @notice The 14-bit flag set this hook's deployment address must match.
    /// @dev    Only BEFORE_SWAP_FLAG is required for dynamic-fee hooks; the
    ///         RETURNS_DELTA variant would only be needed if we also wanted
    ///         to modify the swap amounts, which we don't.
    function permissionsFlags() public pure returns (uint160) {
        return Hooks.BEFORE_SWAP_FLAG;
    }

    // ---------------------------------------------------------------------
    // beforeSwap — the actual SmartFee plumbing
    // ---------------------------------------------------------------------
    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        uint8 tier = _tierFromTickSpacing(key.tickSpacing);
        SpryFeeParams memory params_ = _tierParams(tier);

        PoolId pid = key.toId();
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(pid);
        uint128 liquidity = POOL_MANAGER.getLiquidity(pid);

        uint24 dynamicFee = SmartFeeLib.getDynamicFee(
            sqrtPriceX96,
            liquidity,
            params.zeroForOne,
            params.amountSpecified,
            params_
        );

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Public view-equivalent of the internal tier dispatch.
    ///         Exposes a tier's complete parameter set for external tooling
    ///         (frontends, indexers, simulators) without touching pool state.
    /// @param tier the tier index (0..TIER_COUNT-1)
    function tierParams(uint8 tier) external pure returns (SpryFeeParams memory) {
        return _tierParams(tier);
    }

    /// @notice Maps a pool's `tickSpacing` to its tier index. Pool creators
    ///         pick the desired tickSpacing at `manager.initialize` time,
    ///         which permanently associates the pool with that tier.
    /// @dev Reverts with `InvalidTier` for tickSpacings outside the
    ///      sanctioned set [1, 10, 60, 200, 1000].
    function _tierFromTickSpacing(int24 tickSpacing) internal pure returns (uint8) {
        if (tickSpacing == 1)    return 0;  // STABLE
        if (tickSpacing == 10)   return 1;  // LIKE-ASSET
        if (tickSpacing == 60)   return 2;  // BLUE-CHIP
        if (tickSpacing == 200)  return 3;  // VOLATILE
        if (tickSpacing == 1000) return 4;  // EXOTIC
        revert InvalidTier();
    }

    // ---------------------------------------------------------------------
    // Tier registry — five hardcoded curve parameter sets.
    //
    // v1 ships these as `pure` returns (bytecode immutables). v1.1 will
    // change this to a storage-backed mapping gated by Timelock, with
    // the same shape — no upstream caller changes required.
    //
    // Commit 1 implements tier 2 (BLUE-CHIP) only. The remaining tiers
    // (0, 1, 3, 4) revert with `InvalidTier`; Commit 2 fills them in.
    // ---------------------------------------------------------------------
    function _tierParams(uint8 tier) internal pure returns (SpryFeeParams memory) {
        if (tier == 2) return _tierBlueChip();
        // Tiers 0, 1, 3, 4 are populated in a follow-up commit.
        revert InvalidTier();
    }

    /// @dev Tier 2 — BLUE-CHIP. Matches the v0 SmartFee curve byte-for-byte
    ///      after the V4-pip-native rescale:
    ///        safe   : [-250, +334]   → 3000 pips (0.30%)
    ///        alert  : ramp to 20_000 pips (2.00%) at -500 / +1000
    ///        danger : ramp to 50_000 pips (5.00%) at -1000 / +5000
    ///        cap    : 55_000 pips (5.50%) beyond
    function _tierBlueChip() private pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            // Zone bounds (per-mille delta)
            safeLow:     -250,
            safeHigh:     334,
            alertLow:    -500,
            alertHigh:   1000,
            dangerLow:  -1000,
            dangerHigh:  5000,

            // Linear-zone coefficients (V4-pip-native: × 1000 vs v0 values)
            aLeft:   -68_000_000,
            bLeft:   -14_000_000,
            aRight:   25_370_000,
            bRight:   -5_370_000,

            // Exponential-zone coefficients (× 1000 vs v0 to output V4 pips)
            aLeftExp:    8_000_000_000_000_000_000_000,  // 8.0e21
            bLeftExp:   -1_832_581_463_748_310_200,      // -1.8325814637483102e18
            aRightExp:  15_905_414_575_341_013_000_000,  // 15.905414575341013e21
            bRightExp:   229_072_682_968_538_780,         // 0.22907268296853878e18

            // Constant zones (V4 pips)
            safeFee:  3_000,    // 0.30%
            capFee:  55_000     // 5.50%
        });
    }

    // ---------------------------------------------------------------------
    // IHooks — every other entry point is a pass-through. Permissioned to
    // PoolManager only so they can never be called externally and cannot be
    // used as a re-entry surface.
    // ---------------------------------------------------------------------
    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
