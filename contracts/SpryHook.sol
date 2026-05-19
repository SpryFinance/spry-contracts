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

/// @title SpryHook
/// @notice V4 hook implementing Spry's dynamic fee curve. On every swap the
///         hook reads the pool's current sqrtPriceX96 + liquidity, asks
///         SmartFeeLib what fee that swap's delta should pay, and returns
///         the result as the LP-fee override.
/// @dev    The pool MUST be initialized with `key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG`
///         and the hook MUST be deployed at an address whose low 14 bits
///         match `permissionsFlags()` — use the included HookMiner. Other
///         IHooks entry points are implemented as no-ops for interface
///         completeness and only revert if called by anyone other than the
///         PoolManager.
contract SpryHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotPoolManager();

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
        PoolId pid = key.toId();
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(pid);
        uint128 liquidity = POOL_MANAGER.getLiquidity(pid);

        uint24 dynamicFee = SmartFeeLib.getDynamicFee(
            sqrtPriceX96,
            liquidity,
            params.zeroForOne,
            params.amountSpecified
        );

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
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
