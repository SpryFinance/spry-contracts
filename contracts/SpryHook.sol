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
///         Five hardcoded tiers, dispatched from the pool's `tickSpacing`
///         field (matching Uniswap V3's fee-tier convention):
///
///             tickSpacing    tier               pairs
///             ───────────────────────────────────────────────────────
///                   1        0  STABLE          USDC/USDT, stETH/ETH
///                  10        1  LIKE-ASSET      wstETH/ETH, USDC/USDC.e
///                  60        2  BLUE-CHIP       ETH/USDC, WBTC/ETH
///                 200        3  VOLATILE        ETH/SHIB, ETH/PEPE
///                1000        4  EXOTIC          low-cap / low-cap
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

    /// @notice Number of blocks a pool's cumulative-delta window covers.
    ///         Set at deployment time per chain because block-time differs
    ///         by an order of magnitude across the chains Uniswap V4 targets;
    ///         a single bake-in would either over-protect slow chains or
    ///         under-protect fast ones. Recommended values:
    ///
    ///             Ethereum mainnet  (12 s blocks)  → 1
    ///             Base              ( 2 s blocks)  → 6
    ///             Arbitrum One      (~250 ms)      → 48
    ///             Optimism          ( 2 s blocks)  → 6
    ///             Polygon PoS       (~2 s blocks)  → 6
    ///
    ///         The window covers the time horizon over which a multicall or
    ///         Flashbots-style bundle can be sliced; on faster chains the
    ///         same wall-clock attack window spans more blocks, so the
    ///         BLOCK_WINDOW grows correspondingly. At each new block past
    ///         `windowStart + BLOCK_WINDOW` the pool's `signedCum` resets
    ///         to zero on the next swap.
    uint64 public immutable BLOCK_WINDOW;

    /// @notice Thrown when the constructor is passed `BLOCK_WINDOW = 0`,
    ///         which would degenerate the cumulative tracker into a no-op
    ///         (every swap would observe a fresh-window reset).
    error ZeroBlockWindow();

    /// @notice Per-pool cumulative-delta state. `signedCum` is the running
    ///         sum of per-swap signed deltas within the active window; the
    ///         window resets when `block.number >= windowStart + BLOCK_WINDOW`.
    ///         Fits in a single storage slot (64 + 128 = 192 bits + padding).
    struct PoolWindow {
        uint64  windowStart;
        int128  signedCum;
    }
    mapping(PoolId => PoolWindow) internal _poolWindow;

    IPoolManager public immutable POOL_MANAGER;

    /// @param _poolManager  V4 PoolManager this hook routes to.
    /// @param _blockWindow  Number of blocks a pool's cumulative window
    ///                      covers (chain-specific; see the constant's
    ///                      NatSpec for the recommended per-chain values).
    constructor(IPoolManager _poolManager, uint64 _blockWindow) {
        if (_blockWindow == 0) revert ZeroBlockWindow();
        POOL_MANAGER = _poolManager;
        BLOCK_WINDOW = _blockWindow;
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
    // beforeSwap — cumulative-aware tiered fee dispatch (integral mode).
    //
    // Three cases keyed off how this swap shifts the pool's running
    // signed cumulative delta:
    //
    //   GROWTH   |cumAfter| > |cumBefore|, same sign:
    //              fee = ∫_{|cumBefore|}^{|cumAfter|} curve / (|after| − |before|)
    //              The swap pushes pool further from neutral; charge the
    //              average curve rate over the path traversed.
    //
    //   UNWIND   |cumAfter| < |cumBefore|, same sign:
    //              fee = safeFee
    //              The swap brings the pool toward neutral; charge the
    //              tier's base rate (LP still gets paid, no MEV penalty).
    //
    //   FLIP     sign(cumBefore) != sign(cumAfter), both non-zero:
    //              fee = (safeFee · |before| + ∫_0^{|after|} curve)
    //                    / (|before| + |after|)
    //
    // Window reset: lazy on first hook entry of a new block window.
    //
    // Path-independence: within a single same-trajectory cumulative move
    // the integral telescopes (F(c_n) − F(c_0)), so splitting one big
    // swap into N pieces costs the exact same total fee. This closes
    // the sub-window splitting loophole that an "end-rate" rule would
    // leave open. The full derivation lives on `SmartFeeLib.marginalFee`.
    // ---------------------------------------------------------------------
    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        uint8 tier = _tierFromTickSpacing(key.tickSpacing);
        SpryFeeParams memory params_ = _tierParams(tier);

        PoolId pid = key.toId();
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(pid);
        uint128 liquidity = POOL_MANAGER.getLiquidity(pid);

        // Compute this swap's signed delta (positive = price up, negative = down)
        int256 signedDelta = SmartFeeLib.computeSignedDelta(
            sqrtPriceX96, liquidity, params.zeroForOne, params.amountSpecified
        );

        // Lazy window reset + load
        PoolWindow memory w = _poolWindow[pid];
        if (block.number >= uint256(w.windowStart) + BLOCK_WINDOW) {
            w.windowStart = uint64(block.number);
            w.signedCum = 0;
        }

        int256 cumBefore = int256(w.signedCum);
        int256 cumAfter = cumBefore + signedDelta;

        uint24 dynamicFee = _computeCumulativeFee(cumBefore, cumAfter, params_);

        // Save the new cumulative state (saturate to int128 bounds defensively;
        // realistic cum magnitudes are bounded by ~50_000 in normal use, vastly
        // below int128.max ≈ 1.7e38).
        if (cumAfter > type(int128).max) cumAfter = type(int128).max;
        else if (cumAfter < type(int128).min) cumAfter = type(int128).min;
        w.signedCum = int128(cumAfter);
        _poolWindow[pid] = w;

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Path-independent three-case fee dispatch. Thin wrapper over
    ///      `SmartFeeLib.marginalFee` — kept as an internal entry point so
    ///      that future variants (different unwind treatment, multi-block
    ///      smoothing, etc.) can be slotted in without touching `beforeSwap`.
    function _computeCumulativeFee(
        int256 cumBefore,
        int256 cumAfter,
        SpryFeeParams memory p
    ) internal pure returns (uint24) {
        return SmartFeeLib.marginalFee(cumBefore, cumAfter, p);
    }

    /// @notice Public view-equivalent of the internal tier dispatch.
    ///         Exposes a tier's complete parameter set for external tooling
    ///         (frontends, indexers, simulators) without touching pool state.
    /// @param tier the tier index (0..TIER_COUNT-1)
    function tierParams(uint8 tier) external pure returns (SpryFeeParams memory) {
        return _tierParams(tier);
    }

    /// @notice Read a pool's current cumulative-window state. Returns
    ///         the window's `windowStart` block number and the running
    ///         `signedCum`. The hook itself never reads this externally;
    ///         the getter exists for off-chain monitoring, indexers, and
    ///         the stateful fuzz campaign's cum-bounded invariants.
    /// @param pid the pool's id
    function poolWindow(PoolId pid) external view returns (uint64 windowStart, int128 signedCum) {
        PoolWindow memory w = _poolWindow[pid];
        return (w.windowStart, w.signedCum);
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
    // Tier registry — five hardcoded curve parameter sets returned as
    // `pure` (bytecode immutables, no SLOAD at runtime).
    // ---------------------------------------------------------------------
    function _tierParams(uint8 tier) internal pure returns (SpryFeeParams memory) {
        if (tier == 0) return _tierStable();
        if (tier == 1) return _tierLikeAsset();
        if (tier == 2) return _tierBlueChip();
        if (tier == 3) return _tierVolatile();
        if (tier == 4) return _tierExotic();
        revert InvalidTier();
    }

    /// @dev All five tier coefficient sets are derived from the tier's
    ///      boundary table (4 fee values × 6 zone bounds) by solving for
    ///      C0 continuity at every safe<->alert<->danger transition
    ///      (linear: 2-equation/2-unknown; exponential: log + exponential
    ///      isolation), then baked into bytecode as `pure` immutables.

    /// @dev Tier 0 — STABLE.  safe ±0.01% / alert→0.05% / danger→0.25% / cap 0.50%
    function _tierStable() private pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            safeLow:     -500, safeHigh:     500,
            alertLow:   -1000, alertHigh:   1500,
            dangerLow:  -2000, dangerHigh:  5000,
            aLeft:    -800_000,  bLeft:    -300_000,
            aRight:    400_000,  bRight:   -100_000,
            aLeftExp:    100_000_000_027_179_122_688,
            bLeftExp:    -1_609_437_912_434_100_224,
            aRightExp:   250_848_455_340_571_262_976,
            bRightExp:       459_839_403_552_600_128,
            safeFee:    100,    // 0.01%
            capFee:    5_000    // 0.50%
        });
    }

    /// @dev Tier 1 — LIKE-ASSET.  safe ±0.05% / alert→0.20% / danger→0.50% / cap 1.00%
    function _tierLikeAsset() private pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            safeLow:     -350, safeHigh:     400,
            alertLow:    -700, alertHigh:   1200,
            dangerLow:  -1500, dangerHigh:  5000,
            aLeft:    -4_285_710,  bLeft:    -999_997,
            aRight:    1_875_000,  bRight:   -250_000,
            aLeftExp:    897_082_713_697_571_307_520,
            bLeftExp:    -1_145_363_414_842_693_888,
            aRightExp:  1_497_492_754_575_049_359_360,
            bRightExp:      241_129_139_966_882_912,
            safeFee:     500,    // 0.05%
            capFee:   10_000    // 1.00%
        });
    }

    /// @dev Tier 2 — BLUE-CHIP.  safe ±0.30% / alert→2.00% / danger→5.00% / cap 5.50%
    function _tierBlueChip() private pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            safeLow:     -250, safeHigh:    334,
            alertLow:    -500, alertHigh:  1000,
            dangerLow:  -1000, dangerHigh: 5000,
            aLeft:   -68_000_000,  bLeft:   -14_000_000,
            aRight:   25_525_525,  bRight:   -5_525_525,
            aLeftExp:    8_000_000_001_237_896_396_800,
            bLeftExp:    -1_832_581_463_748_310_272,
            aRightExp:  15_905_414_575_956_300_922_880,
            bRightExp:       229_072_682_968_538_784,
            safeFee:   3_000,   // 0.30%
            capFee:   55_000    // 5.50%
        });
    }

    /// @dev Tier 3 — VOLATILE.  safe ±0.50% / alert→3.00% / danger→7.50% / cap 9.00%
    function _tierVolatile() private pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            safeLow:     -150, safeHigh:    200,
            alertLow:    -350, alertHigh:   600,
            dangerLow:   -700, dangerHigh: 5000,
            aLeft:  -125_000_000,  bLeft:  -13_750_000,
            aRight:   62_500_000,  bRight:  -7_500_000,
            aLeftExp:   12_000_000_001_856_843_546_624,
            bLeftExp:    -2_617_973_519_640_443_392,
            aRightExp:  26_476_264_318_162_022_957_056,
            bRightExp:       208_247_893_607_762_528,
            safeFee:   5_000,   // 0.50%
            capFee:   90_000    // 9.00%
        });
    }

    /// @dev Tier 4 — EXOTIC.  safe ±1.00% / alert→5.00% / danger→9.50% / cap 9.90%
    function _tierExotic() private pure returns (SpryFeeParams memory) {
        return SpryFeeParams({
            safeLow:      -75, safeHigh:    100,
            alertLow:    -200, alertHigh:   400,
            dangerLow:   -500, dangerHigh: 5000,
            aLeft:  -320_000_000,  bLeft:  -14_000_000,
            aRight:  133_333_330,  bRight:  -3_333_332,
            aLeftExp:   32_593_745_518_938_709_557_248,
            bLeftExp:    -2_139_512_953_907_982_336,
            aRightExp:  47_285_780_377_453_805_436_928,
            bRightExp:       139_533_453_515_737_984,
            safeFee:  10_000,   // 1.00%
            capFee:   99_000    // 9.90%
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
