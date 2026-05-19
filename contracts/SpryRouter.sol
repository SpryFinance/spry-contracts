// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {SafeTransfer} from "./libs/SafeTransfer.sol";
import {ModifiedERC6909} from "./ModifiedERC6909.sol";

/// @title SpryRouter
/// @notice Periphery router for swaps on V4 Spry pools. Exposes a V2-style
///         API (exact-in / exact-out, slippage and deadline guards, native
///         ETH first-class) plus unbounded multi-hop. Every external call
///         translates into a single PoolManager.unlock callback. Also tracks
///         per-user full-range LP shares as ERC6909 claims so the V2-style
///         add/removeLiquidity UX is preserved.
contract SpryRouter is IUnlockCallback, ModifiedERC6909 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransfer for address;

    error Expired();
    error InsufficientOutput();
    error ExcessiveInput();
    error NotPoolManager();
    error InvalidCallbackKind();
    error EmptyPath();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientLiquidity();

    // Tags for the unlock callback's tagged-union payload.
    uint8 internal constant TAG_SINGLE = 1;
    uint8 internal constant TAG_MULTI_IN = 2;
    uint8 internal constant TAG_ADD_LIQUIDITY = 3;
    uint8 internal constant TAG_REMOVE_LIQUIDITY = 4;

    enum Kind {
        ExactInputSingle,
        ExactOutputSingle
    }

    struct SingleSwapData {
        Kind kind;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // negative=exactIn, positive=exactOut
        uint256 slippageBound;
        address payer;
        address recipient;
    }

    /// @notice One hop in a multi-hop path. `intermediateCurrency` is the
    ///         token we're swapping INTO at this step. The previous step's
    ///         intermediate (or the user's input currency, for hop 0)
    ///         supplies the from-side currency.
    struct PathHop {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bytes hookData;
    }

    struct MultiInputData {
        Currency currencyIn;
        PathHop[] path;
        uint256 amountIn;
        address payer;
        address recipient;
    }

    struct LiquidityData {
        PoolKey key;
        int256 liquidityDelta;  // signed: + add, - remove
        uint256 amount0Desired; // only used on add for sizing
        uint256 amount1Desired; // only used on add for sizing
        uint256 amount0Min;
        uint256 amount1Min;
        address payer;
        address recipient;
    }

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    receive() external payable {}

    // ---------------------------------------------------------------------
    // Single-hop user entry points
    // ---------------------------------------------------------------------

    function swapExactInputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        SingleSwapData memory data = SingleSwapData({
            kind: Kind.ExactInputSingle,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            slippageBound: amountOutMin,
            payer: msg.sender,
            recipient: recipient
        });
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_SINGLE, abi.encode(data))),
            (uint256)
        );
        if (amountOut < amountOutMin) revert InsufficientOutput();
    }

    function swapExactOutputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        SingleSwapData memory data = SingleSwapData({
            kind: Kind.ExactOutputSingle,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            slippageBound: amountInMax,
            payer: msg.sender,
            recipient: recipient
        });
        amountIn = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_SINGLE, abi.encode(data))),
            (uint256)
        );
        if (amountIn > amountInMax) revert ExcessiveInput();

        if (msg.value > 0) {
            uint256 bal = address(this).balance;
            if (bal > 0) SafeTransfer.safeTransferETH(msg.sender, bal);
        }
    }

    // ---------------------------------------------------------------------
    // Multi-hop user entry point (exact-input only for now)
    // ---------------------------------------------------------------------

    /// @notice Exact-input swap along an arbitrary-length path. Atomic — a
    ///         failure on any hop reverts the entire transaction. The final
    ///         output currency is `path[path.length - 1].intermediateCurrency`.
    ///         For a single-hop swap, prefer `swapExactInputSingle` (lower gas).
    function swapExactInput(
        Currency currencyIn,
        PathHop[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        if (path.length == 0) revert EmptyPath();

        MultiInputData memory data = MultiInputData({
            currencyIn: currencyIn,
            path: path,
            amountIn: amountIn,
            payer: msg.sender,
            recipient: recipient
        });
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_MULTI_IN, abi.encode(data))),
            (uint256)
        );
        if (amountOut < amountOutMin) revert InsufficientOutput();
    }

    // ---------------------------------------------------------------------
    // Liquidity user entry points (full-range only)
    // ---------------------------------------------------------------------

    /// @notice Adds full-range liquidity to `key` using desired amounts. The
    ///         router computes the V4 liquidity value internally from the
    ///         pool's current price and the bounds, applies slippage checks
    ///         against amount{0,1}Min, and mints ERC6909 LP shares to
    ///         `recipient` equal to the liquidity delta.
    function addLiquidity(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        // The actual `liquidity` value is computed inside the unlock callback
        // (which has fresh stack space). The outer function only packs args
        // and dispatches, keeping the live-variable count well under 16 to
        // satisfy the no-via_ir build that `forge coverage` uses.
        LiquidityData memory d = LiquidityData({
            key: key,
            liquidityDelta: 0, // signal: callback computes from desired amounts
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            payer: msg.sender,
            recipient: recipient
        });
        bytes memory ret = POOL_MANAGER.unlock(abi.encode(TAG_ADD_LIQUIDITY, abi.encode(d)));
        (liquidity, amount0, amount1) = abi.decode(ret, (uint128, uint256, uint256));

        _mint(bytes32(PoolId.unwrap(key.toId())), recipient, uint256(liquidity));

        if (msg.value > 0) {
            uint256 bal = address(this).balance;
            if (bal > 0) SafeTransfer.safeTransferETH(msg.sender, bal);
        }
    }

    /// @notice Burns ERC6909 LP shares from msg.sender and returns the
    ///         proportional token amounts to `recipient`. Slippage on each
    ///         currency enforced via amount{0,1}Min.
    function removeLiquidity(
        PoolKey calldata key,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amount0, uint256 amount1) {
        bytes32 id = bytes32(PoolId.unwrap(key.toId()));
        _burn(id, msg.sender, uint256(liquidity));

        LiquidityData memory d = LiquidityData({
            key: key,
            liquidityDelta: -int256(uint256(liquidity)),
            amount0Desired: 0,
            amount1Desired: 0,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            payer: address(0),
            recipient: recipient
        });
        bytes memory ret = POOL_MANAGER.unlock(abi.encode(TAG_REMOVE_LIQUIDITY, abi.encode(d)));
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
    }

    // ---------------------------------------------------------------------
    // Unlock callback — tagged dispatch
    // ---------------------------------------------------------------------

    function unlockCallback(bytes calldata raw) external onlyPoolManager returns (bytes memory) {
        (uint8 tag, bytes memory payload) = abi.decode(raw, (uint8, bytes));

        if (tag == TAG_SINGLE) {
            SingleSwapData memory d = abi.decode(payload, (SingleSwapData));
            return _executeSingle(d);
        } else if (tag == TAG_MULTI_IN) {
            MultiInputData memory d = abi.decode(payload, (MultiInputData));
            return _executeMultiExactInput(d);
        } else if (tag == TAG_ADD_LIQUIDITY) {
            LiquidityData memory d = abi.decode(payload, (LiquidityData));
            return _executeAddLiquidity(d);
        } else if (tag == TAG_REMOVE_LIQUIDITY) {
            LiquidityData memory d = abi.decode(payload, (LiquidityData));
            return _executeRemoveLiquidity(d);
        } else {
            revert InvalidCallbackKind();
        }
    }

    // ---------------------------------------------------------------------
    // Internal: add/remove liquidity executors
    // ---------------------------------------------------------------------

    function _executeAddLiquidity(LiquidityData memory data) internal returns (bytes memory) {
        // Compute liquidity in here so the public addLiquidity() stays under
        // the no-via_ir stack budget.
        uint128 liquidity = _computeLiquidity(data);
        if (liquidity == 0) revert InsufficientLiquidity();

        (BalanceDelta callerDelta,) = POOL_MANAGER.modifyLiquidity(
            data.key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(data.key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(data.key.tickSpacing),
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // For an ADD, callerDelta is negative on both sides (router owes).
        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();
        uint256 amount0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 amount1 = d1 < 0 ? uint256(uint128(-d1)) : 0;

        if (amount0 < data.amount0Min) revert InsufficientAAmount();
        if (amount1 < data.amount1Min) revert InsufficientBAmount();

        _settle(data.key.currency0, data.payer, amount0);
        _settle(data.key.currency1, data.payer, amount1);

        return abi.encode(liquidity, amount0, amount1);
    }

    /// @dev Extracted so the heavy local variables (sqrt prices) live in
    ///      their own frame and don't pile onto _executeAddLiquidity's stack.
    function _computeLiquidity(LiquidityData memory data) private view returns (uint128) {
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

    function _executeRemoveLiquidity(LiquidityData memory data) internal returns (bytes memory) {
        (BalanceDelta callerDelta,) = POOL_MANAGER.modifyLiquidity(
            data.key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(data.key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(data.key.tickSpacing),
                liquidityDelta: data.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // For a REMOVE, callerDelta is positive on both sides (router is owed).
        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();
        uint256 amount0 = d0 > 0 ? uint256(uint128(d0)) : 0;
        uint256 amount1 = d1 > 0 ? uint256(uint128(d1)) : 0;

        if (amount0 < data.amount0Min) revert InsufficientAAmount();
        if (amount1 < data.amount1Min) revert InsufficientBAmount();

        _take(data.key.currency0, data.recipient, amount0);
        _take(data.key.currency1, data.recipient, amount1);

        return abi.encode(amount0, amount1);
    }

    // ---------------------------------------------------------------------
    // Internal: single-hop executor
    // ---------------------------------------------------------------------

    function _executeSingle(SingleSwapData memory data) internal returns (bytes memory) {
        BalanceDelta delta = POOL_MANAGER.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: data.amountSpecified,
                sqrtPriceLimitX96: data.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        uint256 inputAmount;
        uint256 outputAmount;
        if (d0 < 0) {
            inputAmount = uint256(uint128(-d0));
            _settle(data.key.currency0, data.payer, inputAmount);
        }
        if (d1 < 0) {
            inputAmount = uint256(uint128(-d1));
            _settle(data.key.currency1, data.payer, inputAmount);
        }
        if (d0 > 0) {
            outputAmount = uint256(uint128(d0));
            _take(data.key.currency0, data.recipient, outputAmount);
        }
        if (d1 > 0) {
            outputAmount = uint256(uint128(d1));
            _take(data.key.currency1, data.recipient, outputAmount);
        }

        return abi.encode(data.kind == Kind.ExactInputSingle ? outputAmount : inputAmount);
    }

    // ---------------------------------------------------------------------
    // Internal: multi-hop exact-input executor
    // ---------------------------------------------------------------------

    function _executeMultiExactInput(MultiInputData memory data) internal returns (bytes memory) {
        Currency currentIn = data.currencyIn;
        // Use negative amountSpecified to indicate exactIn at the first hop.
        int256 currentAmount = -int256(data.amountIn);
        uint128 lastOutput;

        for (uint256 i = 0; i < data.path.length; i++) {
            PathHop memory hop = data.path[i];
            Currency currentOut = hop.intermediateCurrency;

            bool zeroForOne = Currency.unwrap(currentIn) < Currency.unwrap(currentOut);
            PoolKey memory key = zeroForOne
                ? PoolKey({
                    currency0: currentIn,
                    currency1: currentOut,
                    fee: hop.fee,
                    tickSpacing: hop.tickSpacing,
                    hooks: hop.hooks
                })
                : PoolKey({
                    currency0: currentOut,
                    currency1: currentIn,
                    fee: hop.fee,
                    tickSpacing: hop.tickSpacing,
                    hooks: hop.hooks
                });

            BalanceDelta delta = POOL_MANAGER.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: currentAmount,
                    sqrtPriceLimitX96: zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                hop.hookData
            );

            // The leg we just took has currentOut as the positive-delta side.
            int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
            lastOutput = uint128(outDelta);

            // Pipe the entire output of this hop into the next as exactIn.
            currentAmount = -int256(int128(outDelta));
            currentIn = currentOut;
        }

        // After all hops, the only outstanding non-zero deltas should be:
        //   currencyIn:   -amountIn  (router owes)
        //   final out:    +lastOutput (router is owed)
        _settle(data.currencyIn, data.payer, data.amountIn);
        _take(currentIn, data.recipient, uint256(lastOutput));

        return abi.encode(uint256(lastOutput));
    }

    // ---------------------------------------------------------------------
    // Settle / take helpers — native ETH aware
    // ---------------------------------------------------------------------

    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            address token = Currency.unwrap(currency);
            if (payer == address(this)) {
                token.safeTransfer(address(POOL_MANAGER), amount);
            } else {
                token.safeTransferFrom(payer, address(POOL_MANAGER), amount);
            }
            POOL_MANAGER.settle();
        }
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.take(currency, recipient, amount);
    }
}
