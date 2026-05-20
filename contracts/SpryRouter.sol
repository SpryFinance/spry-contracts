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

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title SpryRouter
/// @notice Periphery router for swaps and liquidity management on Spry pools.
///         Exposes a compact, ergonomic API (exact-in / exact-out single-hop,
///         unbounded multi-hop, add/remove liquidity), slippage and deadline
///         guards, and first-class native-ETH support. Every external call
///         translates into a single PoolManager.unlock callback. Also tracks
///         per-user full-range LP shares via solmate's ERC6909 so
///         add/removeLiquidity round-trips behave like a standard router.
/// @dev    ERC6909 (multi-token ledger) and SafeTransferLib (non-standard
///         ERC20 tolerance) are pulled in from solmate rather than rolled
///         by hand — both are widely audited and already part of the V4
///         core's dependency tree (PoolManager itself inherits ERC6909).
contract SpryRouter is IUnlockCallback, ERC6909, Multicall_v4, Permit2Forwarder {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;

    /// @notice Total minted minus burned per token-id, mirroring the V4
    ///         in-range liquidity backing that id's LP shares. Tracked
    ///         explicitly here because solmate's bare ERC6909 doesn't.
    mapping(uint256 id => uint256) public totalSupply;

    error Expired();
    error InsufficientOutput();
    error ExcessiveInput();
    error NotPoolManager();
    error InvalidCallbackKind();
    error EmptyPath();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientLiquidity();
    /// @notice Permit2 cannot mediate native-ETH transfers — it only knows
    ///         about ERC20s. Raised when a *ViaPermit2 entry point is asked
    ///         to settle a native-ETH leg.
    error Permit2NativeUnsupported();

    // Tags for the unlock callback's tagged-union payload.
    uint8 internal constant TAG_SINGLE = 1;
    uint8 internal constant TAG_MULTI_IN = 2;
    uint8 internal constant TAG_ADD_LIQUIDITY = 3;
    uint8 internal constant TAG_REMOVE_LIQUIDITY = 4;
    uint8 internal constant TAG_MULTI_OUT = 5;

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
        bool usePermit2;
        bytes hookData;
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
        bool usePermit2;
    }

    /// @notice Multi-hop exact-output payload. The forward `path` is the
    ///         same shape as `MultiInputData`: each PathHop's
    ///         intermediateCurrency is the OUTPUT of that hop.
    ///         `currencyIn` is the user's payment side; `amountOut`
    ///         is the exact amount of `path[last].intermediateCurrency`
    ///         the user wants to receive.
    struct MultiOutputData {
        Currency currencyIn;
        PathHop[] path;
        uint256 amountOut;
        address payer;
        address recipient;
        bool usePermit2;
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
        bool usePermit2;
    }

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2) Permit2Forwarder(_permit2) {
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

    /// @notice Forward an EIP-2612 permit signature to a permit-enabled ERC20.
    ///         The token is told that `msg.sender` authorizes the router to
    ///         spend `value` of their balance until `deadline`, using the
    ///         supplied signature. Designed to be chained with a subsequent
    ///         swap or addLiquidity call in a single tx via `multicall`,
    ///         saving the user a separate `approve` transaction.
    /// @dev    `msg.sender` here is the original caller (multicall delegates
    ///         into this contract via DELEGATECALL, preserving msg.sender).
    ///         Wraps the call in try/catch so a front-run permit attack
    ///         (someone else submits the same signature first, causing the
    ///         token's permit() to revert with "permit: invalid signature"
    ///         due to nonce bump) cannot DoS a multicall pipeline. If the
    ///         allowance is already set, the subsequent swap still succeeds.
    function selfPermit(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {
        try IERC20Permit(token).permit(msg.sender, address(this), value, deadline, v, r, s) {}
        catch {}
    }

    /// @dev Snapshot of the router's ETH balance excluding the current call's
    ///      `msg.value`. Used by every payable entry point to refund only
    ///      what this call put on the contract, never any pre-existing
    ///      stuck balance (which a prior bug could otherwise leak to the
    ///      next caller).
    function _ethPriorBalance() internal view returns (uint256) {
        return address(this).balance - msg.value;
    }

    /// @dev Refund any ETH this call deposited on the router but didn't
    ///      consume. Compares against `priorBal` captured at function
    ///      entry so pre-existing balances are never refunded.
    function _refundExcessETH(uint256 priorBal) internal {
        uint256 currentBal = address(this).balance;
        if (currentBal > priorBal) {
            unchecked {
                SafeTransferLib.safeTransferETH(msg.sender, currentBal - priorBal);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Single-hop user entry points
    // ---------------------------------------------------------------------

    function swapExactInputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        bytes calldata hookData
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        uint256 priorBal = _ethPriorBalance();
        SingleSwapData memory data = SingleSwapData({
            kind: Kind.ExactInputSingle,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            slippageBound: amountOutMin,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: false,
            hookData: hookData
        });
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_SINGLE, abi.encode(data))),
            (uint256)
        );
        if (amountOut < amountOutMin) revert InsufficientOutput();
        _refundExcessETH(priorBal);
    }

    function swapExactOutputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline,
        bytes calldata hookData
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        uint256 priorBal = _ethPriorBalance();
        SingleSwapData memory data = SingleSwapData({
            kind: Kind.ExactOutputSingle,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            slippageBound: amountInMax,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: false,
            hookData: hookData
        });
        amountIn = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_SINGLE, abi.encode(data))),
            (uint256)
        );
        if (amountIn > amountInMax) revert ExcessiveInput();
        _refundExcessETH(priorBal);
    }

    /// @notice Permit2 variant of swapExactInputSingle. Pulls the input
    ///         token via Permit2.transferFrom instead of the token's own
    ///         allowance ledger, so the user only needs the standard
    ///         one-time `token.approve(Permit2, max)` plus a Permit2
    ///         signature (typically set via router.permit() in a multicall
    ///         right before this call).
    function swapExactInputSingleViaPermit2(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        bytes calldata hookData
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        uint256 priorBal = _ethPriorBalance();
        SingleSwapData memory data = SingleSwapData({
            kind: Kind.ExactInputSingle,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            slippageBound: amountOutMin,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: true,
            hookData: hookData
        });
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_SINGLE, abi.encode(data))),
            (uint256)
        );
        if (amountOut < amountOutMin) revert InsufficientOutput();
        _refundExcessETH(priorBal);
    }

    /// @notice Permit2 variant of swapExactOutputSingle. See
    ///         swapExactInputSingleViaPermit2 for the prerequisites.
    function swapExactOutputSingleViaPermit2(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline,
        bytes calldata hookData
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        uint256 priorBal = _ethPriorBalance();
        SingleSwapData memory data = SingleSwapData({
            kind: Kind.ExactOutputSingle,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            slippageBound: amountInMax,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: true,
            hookData: hookData
        });
        amountIn = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_SINGLE, abi.encode(data))),
            (uint256)
        );
        if (amountIn > amountInMax) revert ExcessiveInput();
        _refundExcessETH(priorBal);
    }

    // ---------------------------------------------------------------------
    // Multi-hop user entry points
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
        uint256 priorBal = _ethPriorBalance();

        MultiInputData memory data = MultiInputData({
            currencyIn: currencyIn,
            path: path,
            amountIn: amountIn,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: false
        });
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_MULTI_IN, abi.encode(data))),
            (uint256)
        );
        if (amountOut < amountOutMin) revert InsufficientOutput();
        _refundExcessETH(priorBal);
    }

    /// @notice Permit2 variant of swapExactInput. See
    ///         swapExactInputSingleViaPermit2 for the prerequisites.
    function swapExactInputViaPermit2(
        Currency currencyIn,
        PathHop[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        if (path.length == 0) revert EmptyPath();
        uint256 priorBal = _ethPriorBalance();

        MultiInputData memory data = MultiInputData({
            currencyIn: currencyIn,
            path: path,
            amountIn: amountIn,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: true
        });
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_MULTI_IN, abi.encode(data))),
            (uint256)
        );
        if (amountOut < amountOutMin) revert InsufficientOutput();
        _refundExcessETH(priorBal);
    }

    /// @notice Exact-output swap along an arbitrary-length path. The user
    ///         specifies the FINAL output currency amount they want; the
    ///         router walks the path BACKWARDS to determine the required
    ///         input amount of `currencyIn`. Atomic, slippage-checked
    ///         against `amountInMax`. For a single-hop swap, prefer
    ///         `swapExactOutputSingle` (lower gas).
    /// @param  currencyIn the user pays from this currency (= the first
    ///                    hop's input side)
    /// @param  path       same forward path representation as `swapExactInput`:
    ///                    each PathHop's intermediateCurrency is that hop's
    ///                    OUTPUT. path[last].intermediateCurrency is the
    ///                    final output the user wants.
    /// @param  amountOut  exact amount of path[last].intermediateCurrency
    ///                    to be delivered to `recipient`
    /// @param  amountInMax revert ceiling on the input amount the user pays
    function swapExactOutput(
        Currency currencyIn,
        PathHop[] calldata path,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        if (path.length == 0) revert EmptyPath();
        uint256 priorBal = _ethPriorBalance();

        MultiOutputData memory data = MultiOutputData({
            currencyIn: currencyIn,
            path: path,
            amountOut: amountOut,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: false
        });
        amountIn = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_MULTI_OUT, abi.encode(data))),
            (uint256)
        );
        if (amountIn > amountInMax) revert ExcessiveInput();
        _refundExcessETH(priorBal);
    }

    /// @notice Permit2 variant of swapExactOutput. See
    ///         swapExactInputSingleViaPermit2 for the prerequisites.
    function swapExactOutputViaPermit2(
        Currency currencyIn,
        PathHop[] calldata path,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        if (path.length == 0) revert EmptyPath();
        uint256 priorBal = _ethPriorBalance();

        MultiOutputData memory data = MultiOutputData({
            currencyIn: currencyIn,
            path: path,
            amountOut: amountOut,
            payer: msg.sender,
            recipient: recipient,
            usePermit2: true
        });
        amountIn = abi.decode(
            POOL_MANAGER.unlock(abi.encode(TAG_MULTI_OUT, abi.encode(data))),
            (uint256)
        );
        if (amountIn > amountInMax) revert ExcessiveInput();
        _refundExcessETH(priorBal);
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
        uint256 priorBal = _ethPriorBalance();
        {
            LiquidityData memory d = LiquidityData({
                key: key,
                liquidityDelta: 0, // signal: callback computes from desired amounts
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                payer: msg.sender,
                recipient: recipient,
                usePermit2: false
            });
            bytes memory ret = POOL_MANAGER.unlock(abi.encode(TAG_ADD_LIQUIDITY, abi.encode(d)));
            (liquidity, amount0, amount1) = abi.decode(ret, (uint128, uint256, uint256));
        }

        _mintLPShares(key, recipient, liquidity);
        _refundExcessETH(priorBal);
    }

    /// @notice Permit2 variant of addLiquidity. Both currencies are pulled
    ///         from the payer via Permit2.transferFrom. Native-ETH pools
    ///         are not supported (Permit2 cannot mediate ETH); use the
    ///         regular `addLiquidity` for those.
    function addLiquidityViaPermit2(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        uint256 priorBal = _ethPriorBalance();
        {
            LiquidityData memory d = LiquidityData({
                key: key,
                liquidityDelta: 0,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                payer: msg.sender,
                recipient: recipient,
                usePermit2: true
            });
            bytes memory ret = POOL_MANAGER.unlock(abi.encode(TAG_ADD_LIQUIDITY, abi.encode(d)));
            (liquidity, amount0, amount1) = abi.decode(ret, (uint128, uint256, uint256));
        }

        _mintLPShares(key, recipient, liquidity);
        _refundExcessETH(priorBal);
    }

    /// @dev Small wrapper so the inline _mint call in `addLiquidity` doesn't
    ///      add to that function's stack budget under the no-via_ir build.
    function _mintLPShares(PoolKey calldata key, address recipient, uint128 liquidity) private {
        _mint(recipient, uint256(PoolId.unwrap(key.toId())), uint256(liquidity));
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
        _burn(msg.sender, uint256(PoolId.unwrap(key.toId())), uint256(liquidity));

        LiquidityData memory d = LiquidityData({
            key: key,
            liquidityDelta: -int256(uint256(liquidity)),
            amount0Desired: 0,
            amount1Desired: 0,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            payer: address(0),
            recipient: recipient,
            usePermit2: false   // removal never pulls from payer; flag unused
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
        } else if (tag == TAG_MULTI_OUT) {
            MultiOutputData memory d = abi.decode(payload, (MultiOutputData));
            return _executeMultiExactOutput(d);
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

        _settle(data.key.currency0, data.payer, amount0, data.usePermit2);
        _settle(data.key.currency1, data.payer, amount1, data.usePermit2);

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
            data.hookData
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        uint256 inputAmount;
        uint256 outputAmount;
        if (d0 < 0) {
            inputAmount = uint256(uint128(-d0));
            _settle(data.key.currency0, data.payer, inputAmount, data.usePermit2);
        }
        if (d1 < 0) {
            inputAmount = uint256(uint128(-d1));
            _settle(data.key.currency1, data.payer, inputAmount, data.usePermit2);
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
        _settle(data.currencyIn, data.payer, data.amountIn, data.usePermit2);
        _take(currentIn, data.recipient, uint256(lastOutput));

        return abi.encode(uint256(lastOutput));
    }

    // ---------------------------------------------------------------------
    // Internal: multi-hop exact-output executor
    //
    // The user provides the SAME forward path representation as exact-input
    // (each PathHop's intermediateCurrency is the OUTPUT of that hop) plus
    // the desired final output amount. The executor walks the path in
    // REVERSE: the last hop runs first with `amountSpecified = +amountOut`,
    // and the input amount it required becomes the exact-output target for
    // the previous hop, and so on. Each pool's swap state is independent,
    // so reversing the iteration order is safe.
    // ---------------------------------------------------------------------
    function _executeMultiExactOutput(MultiOutputData memory data) internal returns (bytes memory) {
        uint256 n = data.path.length;
        Currency currentOut = data.path[n - 1].intermediateCurrency;
        int256 currentAmount = int256(data.amountOut); // positive = exactOut
        uint256 amountInRequired;

        // Walk the path in reverse: i = n-1, n-2, ..., 0.
        for (uint256 step = 0; step < n; ++step) {
            uint256 i = n - 1 - step;
            Currency currentIn = (i == 0)
                ? data.currencyIn
                : data.path[i - 1].intermediateCurrency;

            uint256 inAmount = _runExactOutHop(data.path[i], currentIn, currentOut, currentAmount);

            currentAmount = int256(inAmount);
            currentOut = currentIn;
            if (i == 0) amountInRequired = inAmount;
        }

        _settle(data.currencyIn, data.payer, amountInRequired, data.usePermit2);
        _take(data.path[n - 1].intermediateCurrency, data.recipient, data.amountOut);

        return abi.encode(amountInRequired);
    }

    /// @dev Extracted to keep `_executeMultiExactOutput`'s stack budget under
    ///      the no-via_ir limit. Runs a single exact-output hop and returns
    ///      the input amount the swap consumed.
    function _runExactOutHop(
        PathHop memory hop,
        Currency currentIn,
        Currency currentOut,
        int256 amountSpecified
    ) private returns (uint256 inAmount) {
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
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            hop.hookData
        );

        // The input side's delta is negative (router owes). Magnitude = the
        // input the swap consumed.
        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        inAmount = uint256(uint128(-inDelta));
    }

    // ---------------------------------------------------------------------
    // Settle / take helpers — native ETH aware
    // ---------------------------------------------------------------------

    /// @param usePermit2 when true, ERC20 transfers route through
    ///                   `Permit2.transferFrom` instead of the token's own
    ///                   allowance ledger. Native-ETH legs ignore the flag.
    function _settle(Currency currency, address payer, uint256 amount, bool usePermit2) internal {
        if (amount == 0) return;
        POOL_MANAGER.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            // Native ETH: Permit2 has no role here. Reject explicitly when
            // a caller asked for Permit2 on an ETH leg so the misuse is
            // visible rather than silently downgrading.
            if (usePermit2) revert Permit2NativeUnsupported();
            POOL_MANAGER.settle{value: amount}();
        } else {
            address tokenAddr = Currency.unwrap(currency);
            if (payer == address(this)) {
                ERC20(tokenAddr).safeTransfer(address(POOL_MANAGER), amount);
            } else if (usePermit2) {
                // Permit2's transferFrom requires the caller (this router)
                // to have a Permit2-recorded allowance from `payer`. The
                // user typically grants it via `router.permit(...)` in the
                // same multicall right before the swap.
                permit2.transferFrom(payer, address(POOL_MANAGER), uint160(amount), tokenAddr);
            } else {
                ERC20(tokenAddr).safeTransferFrom(payer, address(POOL_MANAGER), amount);
            }
            POOL_MANAGER.settle();
        }
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.take(currency, recipient, amount);
    }

    // ---------------------------------------------------------------------
    // ERC6909 mint / burn overrides — keep totalSupply in sync.
    // ---------------------------------------------------------------------

    function _mint(address receiver, uint256 id, uint256 amount) internal override {
        super._mint(receiver, id, amount);
        totalSupply[id] += amount;
    }

    function _burn(address sender, uint256 id, uint256 amount) internal override {
        super._burn(sender, id, amount);
        unchecked {
            // Underflow impossible — super._burn already reverts when the
            // sender's balance is below `amount`, and totalSupply by
            // construction is the sum of all balances.
            totalSupply[id] -= amount;
        }
    }
}
