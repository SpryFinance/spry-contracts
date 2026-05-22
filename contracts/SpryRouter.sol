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

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";

/// @title SpryRouter
/// @notice Periphery swap router for Spry pools. Exposes a compact,
///         ergonomic API (exact-in / exact-out single-hop, unbounded
///         multi-hop), slippage and deadline guards, and first-class
///         native-ETH support. Every external call translates into a
///         single PoolManager.unlock callback.
/// @dev    Liquidity management (add / remove / increase / decrease) is
///         delegated to Uniswap's canonical `PositionManager` from
///         v4-periphery — it mints an ERC721 NFT per LP position with
///         per-position fee accounting handled by V4 itself. Mirroring
///         Uniswap's UniversalRouter + PositionManager split: SpryRouter
///         is swap-only, PositionManager is LP-only. The two contracts
///         operate independently against the shared V4 PoolManager and
///         the shared SpryHook.
/// @dev    SafeTransferLib (non-standard ERC20 tolerance) is pulled in
///         from solmate rather than rolled by hand — already audited and
///         part of the V4 core dependency tree.
/// @dev    multicall caveat: `multicall(bytes[])` (inherited from
///         v4-periphery's `Multicall_v4`) is `payable`, and `msg.value`
///         is preserved across every inner delegatecall. The ETH-refund
///         logic on this router fires from inside each swap entry point
///         against a balance snapshot at that entry point — the multicall
///         wrapper itself does not refund. As a result, a multicall whose
///         payload contains no ETH-consuming inner call (e.g.
///         `[selfPermit, permit2.permit]` with `value > 0`) leaves the
///         supplied ETH on the router. The router has no admin / sweep /
///         rescue function, so that ETH is permanently inaccessible.
///         Callers should NOT attach `msg.value` to a multicall whose
///         inner calls do not themselves consume ETH. The official
///         Multicall_v4 is not `virtual` so this router cannot override
///         it to add a refund step; the constraint is therefore expressed
///         as a documented caveat rather than a code-level guard.
contract SpryRouter is IUnlockCallback, Multicall_v4, Permit2Forwarder {
    using SafeTransferLib for ERC20;

    error Expired();
    error InsufficientOutput();
    error ExcessiveInput();
    error NotPoolManager();
    error InvalidCallbackKind();
    error EmptyPath();
    /// @notice Permit2 cannot mediate native-ETH transfers — it only knows
    ///         about ERC20s. Raised when a *ViaPermit2 entry point is asked
    ///         to settle a native-ETH leg.
    error Permit2NativeUnsupported();
    /// @notice Permit2.transferFrom expects a uint160 amount. Raised when an
    ///         amount that would silently truncate is encountered. Reachable
    ///         only by astronomically large values; the guard exists for
    ///         defense-in-depth.
    error Permit2AmountOverflow();
    /// @notice `recipient` cannot be the router itself. The router has no
    ///         admin / sweep / rescue function, so tokens delivered to it
    ///         are permanently stuck. ETH-output swaps would self-recover
    ///         via the refund path, but ERC20 outputs would not — rejecting
    ///         uniformly is the only safe default.
    error InvalidRecipient();
    /// @notice A user-supplied uint256 amount would not fit in int256
    ///         without setting the sign bit. The router casts amounts to
    ///         int256 for V4 SwapParams.amountSpecified; in Solidity 0.8.x
    ///         that cast is a bit reinterpretation, so any value with bit
    ///         255 set silently becomes negative and flips exactIn/exactOut
    ///         semantics. Bound exists for defense-in-depth — reaching it
    ///         requires astronomically large (~5.79e76) amounts.
    error AmountTooLarge();
    /// @notice A multi-hop path has a hop whose `intermediateCurrency`
    ///         equals the previous hop's currency. The resulting PoolKey
    ///         would have `currency0 == currency1`, which V4 cannot
    ///         initialize. Surface the misconfiguration with a clear error
    ///         rather than the obscure pool-not-initialized revert.
    error InvalidPath();

    // Tags for the unlock callback's tagged-union payload.
    uint8 internal constant TAG_SINGLE = 1;
    uint8 internal constant TAG_MULTI_IN = 2;
    uint8 internal constant TAG_MULTI_OUT = 3;

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

    /// @notice One hop in a multi-hop path is described by the canonical
    ///         `PathKey` type from v4-periphery: `intermediateCurrency` is
    ///         the token we're swapping INTO at this step; the previous
    ///         step's intermediate (or the user's input currency, for hop 0)
    ///         supplies the from-side currency.
    /// @dev    Using `PathKey` directly (instead of a local clone) means the
    ///         same struct works for both swaps through this router and
    ///         quotes through V4Quoter — integrators only learn one shape.

    struct MultiInputData {
        Currency currencyIn;
        PathKey[] path;
        uint256 amountIn;
        address payer;
        address recipient;
        bool usePermit2;
    }

    /// @notice Multi-hop exact-output payload. Follows the V4Router /
    ///         V4Quoter path-encoding convention so the same `PathKey[]`
    ///         that we accept here is directly usable as
    ///         `QuoteExactParams.path` for `V4Quoter.quoteExactOutput`.
    ///
    ///         Path semantics (for a swap A -> B -> C, user wants exact C):
    ///           currencyOut                  = C   (user's output)
    ///           path[0].intermediateCurrency = A   (user's INPUT side)
    ///           path[1].intermediateCurrency = B   (mid-chain currency)
    ///         Equivalently: at each iteration step starting from the
    ///         tail of `path`, `path[i].intermediateCurrency` is the
    ///         "from-side" of that hop (= the previous hop's output, or
    ///         the user's input for `path[0]`).
    struct MultiOutputData {
        Currency currencyOut;
        PathKey[] path;
        uint256 amountOut;
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
    ///         swap call in a single tx via `multicall`, saving the user a
    ///         separate `approve` transaction.
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

    /// @dev Reverts with `Permit2NativeUnsupported` if `c` is native ETH.
    ///      `*ViaPermit2` entry points use this to fail fast at the entry
    ///      point boundary rather than after a wasted unlock round-trip.
    function _assertNotNative(Currency c) internal pure {
        if (Currency.unwrap(c) == address(0)) revert Permit2NativeUnsupported();
    }

    /// @dev Reverts with `InvalidRecipient` if `recipient` is this router.
    ///      Tokens delivered to the router cannot be recovered (no admin,
    ///      no sweep). Every external entry point that takes a recipient
    ///      pipes it through this guard so a typo or buggy frontend can't
    ///      silently sink funds.
    function _assertRecipient(address recipient) internal view {
        if (recipient == address(this)) revert InvalidRecipient();
    }

    /// @dev Reverts with `AmountTooLarge` if `amount` would set the sign
    ///      bit of an int256. Wired at every swap entry point so the
    ///      uint256 -> int256 reinterpretation downstream can never flip
    ///      exactIn/exactOut semantics or overflow on negation.
    function _assertAmountFitsInt256(uint256 amount) internal pure {
        if (amount > uint256(type(int256).max)) revert AmountTooLarge();
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
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountIn);
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
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountOut);
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
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountIn);
        _assertNotNative(zeroForOne ? key.currency0 : key.currency1);
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
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountOut);
        _assertNotNative(zeroForOne ? key.currency0 : key.currency1);
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
        PathKey[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountIn);
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
        PathKey[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountOut) {
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountIn);
        if (path.length == 0) revert EmptyPath();
        _assertNotNative(currencyIn);
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
    ///         specifies the FINAL output currency and amount; the router
    ///         walks the path BACKWARDS to determine the required input
    ///         amount. Atomic, slippage-checked against `amountInMax`.
    ///         For a single-hop swap, prefer `swapExactOutputSingle`
    ///         (lower gas).
    /// @dev    Path encoding matches V4Router / V4Quoter — see the
    ///         `MultiOutputData` NatSpec for the rules. In short: for a
    ///         swap A -> B -> C with `currencyOut = C`, the path is
    ///         `[{intermediateCurrency: A}, {intermediateCurrency: B}]`.
    /// @param  currencyOut the user receives this currency (= the last
    ///                     hop's output side)
    /// @param  path        per-hop key data, with `path[i].intermediateCurrency`
    ///                     being the FROM-side of hop i. `path[0]` is the
    ///                     user's payment currency.
    /// @param  amountOut   exact amount of `currencyOut` to deliver to
    ///                     `recipient`
    /// @param  amountInMax revert ceiling on the input amount the user pays
    function swapExactOutput(
        Currency currencyOut,
        PathKey[] calldata path,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountOut);
        if (path.length == 0) revert EmptyPath();
        uint256 priorBal = _ethPriorBalance();

        MultiOutputData memory data = MultiOutputData({
            currencyOut: currencyOut,
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
        Currency currencyOut,
        PathKey[] calldata path,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountIn) {
        _assertRecipient(recipient);
        _assertAmountFitsInt256(amountOut);
        if (path.length == 0) revert EmptyPath();
        // path[0].intermediateCurrency is the user's input under the V4
        // reverse-path convention; reject native ETH there since Permit2
        // can't mediate it.
        _assertNotNative(path[0].intermediateCurrency);
        uint256 priorBal = _ethPriorBalance();

        MultiOutputData memory data = MultiOutputData({
            currencyOut: currencyOut,
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
        } else {
            revert InvalidCallbackKind();
        }
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
            PathKey memory hop = data.path[i];
            Currency currentOut = hop.intermediateCurrency;
            // currentIn must differ from currentOut — otherwise the derived
            // PoolKey would have currency0 == currency1, which V4 cannot
            // initialize. Fail with a clear error instead.
            if (currentIn == currentOut) revert InvalidPath();

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
    // Path-encoding convention matches V4Router / V4Quoter:
    //
    //   For a swap A -> B -> C, user wants exact C:
    //     data.currencyOut             = C
    //     data.path[0].intermediateCurrency = A   (user's INPUT)
    //     data.path[1].intermediateCurrency = B   (intermediate)
    //
    // The executor walks the path in REVERSE: iteration step 0 looks at
    // path[n-1] and swaps `path[n-1].intermediateCurrency` -> currencyOut
    // with exactOut = amountOut. The input amount required becomes the
    // exactOut target for the previous step, and so on. After step n-1
    // (which uses path[0]), the final input amount has been computed and
    // we settle the input + take the output.
    //
    // Each pool's swap state is independent across hops, so reversing the
    // iteration order is safe even though pool state mutates per swap.
    // ---------------------------------------------------------------------
    function _executeMultiExactOutput(MultiOutputData memory data) internal returns (bytes memory) {
        uint256 n = data.path.length;
        Currency currentOut = data.currencyOut;
        int256 currentAmount = int256(data.amountOut); // positive = exactOut
        uint256 amountInRequired;

        // Walk the path in reverse: i = n-1, n-2, ..., 0.
        for (uint256 step = 0; step < n; ++step) {
            uint256 i = n - 1 - step;
            // `path[i].intermediateCurrency` is the from-side of this hop.
            Currency currentIn = data.path[i].intermediateCurrency;
            // Reject degenerate hops where the from- and to-side coincide:
            // V4 cannot initialize a pool with currency0 == currency1.
            if (currentIn == currentOut) revert InvalidPath();

            uint256 inAmount = _runExactOutHop(data.path[i], currentIn, currentOut, currentAmount);

            currentAmount = int256(inAmount);
            currentOut = currentIn;
            if (i == 0) amountInRequired = inAmount;
        }

        // After the loop, `path[0].intermediateCurrency` is the user's input.
        Currency payerCurrency = data.path[0].intermediateCurrency;
        _settle(payerCurrency, data.payer, amountInRequired, data.usePermit2);
        _take(data.currencyOut, data.recipient, data.amountOut);

        return abi.encode(amountInRequired);
    }

    /// @dev Extracted to keep `_executeMultiExactOutput`'s stack budget under
    ///      the no-via_ir limit. Runs a single exact-output hop and returns
    ///      the input amount the swap consumed.
    function _runExactOutHop(
        PathKey memory hop,
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
        //
        // Note: `-inDelta` would overflow if `inDelta == type(int128).min`,
        // i.e. magnitude == 2^127 (~1.7e38). That is orders of magnitude
        // beyond any realistic pool's reserves (full-range V4 positions sit
        // well under uint128.max), and an attempt to swap that much would
        // already have reverted inside V4's tick-math before we got here.
        // The same caveat applies to the `-d0` / `-d1` negations in
        // `_executeSingle` and `_executeMultiExactInput`. Documented once.
        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        inAmount = uint256(uint128(-inDelta));
    }

    // ---------------------------------------------------------------------
    // Settle / take helpers — native ETH aware
    // ---------------------------------------------------------------------

    /// @param usePermit2 when true, ERC20 transfers route through
    ///                   `Permit2.transferFrom` instead of the token's own
    ///                   allowance ledger. Native-ETH legs ignore the flag.
    /// @dev `payer` is always `msg.sender`: every call site that reaches
    ///      `_settle` sets `data.payer = msg.sender`, so the router itself
    ///      never owes a settle on its own behalf.
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
            if (usePermit2) {
                // Permit2's transferFrom requires the caller (this router)
                // to have a Permit2-recorded allowance from `payer`. The
                // user typically grants it via `router.permit(...)` in the
                // same multicall right before the swap.
                if (amount > type(uint160).max) revert Permit2AmountOverflow();
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
}
