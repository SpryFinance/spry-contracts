// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title LPHelper
/// @notice Test-only liquidity helper for the SpryRouter test suite.
///
///         SpryRouter is now swap-only; in production users interact with
///         Uniswap's canonical PositionManager for LP UX. Dragging the full
///         PositionManager dependency chain (tokenDescriptor, WETH9,
///         unsubscribeGasLimit, ERC721Permit, ...) into every test fixture
///         would balloon test setup without adding test value. This helper
///         is the slim alternative: drives PoolManager.modifyLiquidity
///         directly so tests can seed full-range positions with one call.
///
///         Fairness model matches PositionManager: each `owner` parameter
///         maps to a unique V4 position via `salt = bytes32(uint256(uint160(owner)))`.
///         V4's per-position fee accounting then takes care of pro-rata
///         fee distribution natively — different owners cannot drain each
///         other's fees by being the first to touch the position.
///
///         One dedicated interop test (test/integration/PositionManagerInteropTest.t.sol)
///         exercises Uniswap's actual PositionManager against our pools so
///         we have end-to-end coverage of the canonical LP UX. Every other
///         test seeds liquidity through `lp.addLiquidity` here.
contract LPHelper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;

    error NotPoolManager();
    error InsufficientLiquidity();
    error InvalidCallbackKind();
    error NativeAmountMismatch();

    uint8 internal constant TAG_ADD    = 1;
    uint8 internal constant TAG_REMOVE = 2;

    struct AddData {
        PoolKey key;
        uint256 amount0Desired;
        uint256 amount1Desired;
        address owner;          // also the payer
        address recipient;      // receives leftover ETH on native pools
    }

    struct RemoveData {
        PoolKey key;
        uint128 liquidity;
        address owner;          // position owner (salt source)
        address recipient;      // receives the unwound tokens
    }

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    receive() external payable {}

    // -----------------------------------------------------------------
    // Salt = per-owner — what V4's PositionManager does with tokenId.
    // -----------------------------------------------------------------
    function _saltFor(address owner) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }

    /// @notice Read the current liquidity of `owner`'s position on `key`.
    function positionLiquidity(PoolKey memory key, address owner) external view returns (uint128) {
        bytes32 positionKey = keccak256(
            abi.encodePacked(
                address(this),
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                _saltFor(owner)
            )
        );
        return POOL_MANAGER.getPositionLiquidity(key.toId(), positionKey);
    }

    // -----------------------------------------------------------------
    // Add liquidity (full-range, per-owner salt)
    // -----------------------------------------------------------------
    function addLiquidity(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address owner
    ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        AddData memory d = AddData({
            key: key,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            owner: owner,
            recipient: owner
        });
        bytes memory ret = POOL_MANAGER.unlock(abi.encode(TAG_ADD, abi.encode(d)));
        (liquidity, amount0, amount1) = abi.decode(ret, (uint128, uint256, uint256));

        // Refund any unused ETH the caller forwarded.
        if (address(this).balance > 0) {
            (bool ok, ) = msg.sender.call{value: address(this).balance}("");
            require(ok, "LPHelper: ETH refund failed");
        }
    }

    // -----------------------------------------------------------------
    // Remove liquidity from `owner`'s position; send tokens to `recipient`.
    // -----------------------------------------------------------------
    function removeLiquidity(
        PoolKey memory key,
        uint128 liquidity,
        address owner,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1) {
        RemoveData memory d = RemoveData({
            key: key,
            liquidity: liquidity,
            owner: owner,
            recipient: recipient
        });
        bytes memory ret = POOL_MANAGER.unlock(abi.encode(TAG_REMOVE, abi.encode(d)));
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
    }

    // -----------------------------------------------------------------
    // Unlock callback — tagged dispatch
    // -----------------------------------------------------------------
    function unlockCallback(bytes calldata raw) external onlyPoolManager returns (bytes memory) {
        (uint8 tag, bytes memory payload) = abi.decode(raw, (uint8, bytes));
        if (tag == TAG_ADD) {
            return _executeAdd(abi.decode(payload, (AddData)));
        } else if (tag == TAG_REMOVE) {
            return _executeRemove(abi.decode(payload, (RemoveData)));
        }
        revert InvalidCallbackKind();
    }

    function _executeAdd(AddData memory data) internal returns (bytes memory) {
        uint128 liquidity = _computeLiquidity(data);
        if (liquidity == 0) revert InsufficientLiquidity();

        (BalanceDelta callerDelta, ) = POOL_MANAGER.modifyLiquidity(
            data.key,
            ModifyLiquidityParams({
                tickLower:      TickMath.minUsableTick(data.key.tickSpacing),
                tickUpper:      TickMath.maxUsableTick(data.key.tickSpacing),
                liquidityDelta: int256(uint256(liquidity)),
                salt:           _saltFor(data.owner)
            }),
            ""
        );

        // Per-position salt + fresh position means callerDelta is negative
        // on both sides (no prior fees to credit). Settle the gross amount.
        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();
        uint256 amount0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 amount1 = d1 < 0 ? uint256(uint128(-d1)) : 0;

        _settle(data.key.currency0, data.owner, amount0);
        _settle(data.key.currency1, data.owner, amount1);

        // If the position somehow accrued fees between mint and this call
        // (impossible with per-owner salt + fresh position, but defensive):
        // take any positive delta so V4's unlock doesn't revert on
        // CurrencyNotSettled.
        if (d0 > 0) POOL_MANAGER.take(data.key.currency0, data.recipient, uint256(uint128(d0)));
        if (d1 > 0) POOL_MANAGER.take(data.key.currency1, data.recipient, uint256(uint128(d1)));

        return abi.encode(liquidity, amount0, amount1);
    }

    function _executeRemove(RemoveData memory data) internal returns (bytes memory) {
        (BalanceDelta callerDelta, ) = POOL_MANAGER.modifyLiquidity(
            data.key,
            ModifyLiquidityParams({
                tickLower:      TickMath.minUsableTick(data.key.tickSpacing),
                tickUpper:      TickMath.maxUsableTick(data.key.tickSpacing),
                liquidityDelta: -int256(uint256(data.liquidity)),
                salt:           _saltFor(data.owner)
            }),
            ""
        );

        // For a remove on a position that accrued fees, callerDelta is
        // positive on both sides (principal + position-scoped fees).
        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();
        uint256 amount0 = d0 > 0 ? uint256(uint128(d0)) : 0;
        uint256 amount1 = d1 > 0 ? uint256(uint128(d1)) : 0;

        if (amount0 > 0) POOL_MANAGER.take(data.key.currency0, data.recipient, amount0);
        if (amount1 > 0) POOL_MANAGER.take(data.key.currency1, data.recipient, amount1);

        return abi.encode(amount0, amount1);
    }

    function _computeLiquidity(AddData memory data) internal view returns (uint128) {
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(data.key.toId());
        if (sqrtPriceX96 == 0) revert InsufficientLiquidity();
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(data.key.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(data.key.tickSpacing)),
            data.amount0Desired,
            data.amount1Desired
        );
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            if (address(this).balance < amount) revert NativeAmountMismatch();
            POOL_MANAGER.settle{value: amount}();
        } else {
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }
}
