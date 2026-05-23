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

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title WindowLengthVariation
/// @notice The cumulative window length (`BLOCK_WINDOW`) is a per-chain
///         immutable picked by the deployer to cover the same wall-clock
///         attack horizon on every chain. Every other test in this repo
///         exercises the canonical mainnet value (1). This suite replays
///         the cumulative-tracker behavior under the larger Base-like
///         (6) and Arbitrum-like (48) values to confirm the lazy-reset
///         arithmetic has no off-by-one at non-trivial window lengths.
///
///         For each window length the suite verifies:
///           - cum accumulates monotonically within a window
///           - the window resets to (block.number, 0) on the first swap
///             past windowStart + BLOCK_WINDOW
///           - the reset does NOT fire one block early
contract WindowLengthVariation is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function _deployHookWithWindow(uint64 blockWindow) internal returns (SpryHook hook) {
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, blockWindow)
        );
        hook = new SpryHook{salt: salt}(manager, blockWindow);
        require(address(hook) == predicted, "hook addr mismatch");
    }

    function _initPool(SpryHook hook) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        lp.addLiquidity(key, 1e22, 1e22, address(this));
    }

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Parametric helper — replays the same cumulative-tracker contract
    // against an arbitrary BLOCK_WINDOW.
    // ------------------------------------------------------------------
    function _checkWindowBehavior(uint64 blockWindow) internal {
        SpryHook hook = _deployHookWithWindow(blockWindow);
        PoolKey memory key = _initPool(hook);
        PoolId pid = key.toId();

        // Foundry starts at block.number = 1; the lazy-reset condition
        // (`block.number >= windowStart + BLOCK_WINDOW`) requires the
        // current block to be at least `BLOCK_WINDOW` for the very first
        // swap (against the default `windowStart = 0`) to actually reset.
        // Roll well past that threshold so the test exercises the stable
        // regime every real chain operates in.
        vm.roll(block.number + uint256(blockWindow) + 10);

        // 1. First swap (in the stable regime) establishes the window.
        //    cum != 0, windowStart = block.number.
        router.swapExactInputSingle(key, true, 5e20, 1, address(this), block.timestamp + 100, "");
        (uint64 wsAfterFirst, int128 cumAfterFirst) = hook.poolWindow(pid);
        assertEq(uint256(wsAfterFirst), block.number, "first-swap windowStart != block.number");
        assertLt(int256(cumAfterFirst), 0, "first-swap cum should be negative (token1 leaving)");

        // 2. Roll forward by (BLOCK_WINDOW - 1) blocks — still inside
        //    the active window. The next swap should CONTINUE the
        //    cumulative, not reset it.
        if (blockWindow > 1) {
            vm.roll(block.number + uint256(blockWindow) - 1);
            router.swapExactInputSingle(key, true, 5e20, 1, address(this), block.timestamp + 100, "");
            (uint64 wsInside, int128 cumInside) = hook.poolWindow(pid);
            assertEq(uint256(wsInside), uint256(wsAfterFirst), "windowStart drifted inside the window");
            assertLt(int256(cumInside), int256(cumAfterFirst), "cum did not continue inside the window");
        }

        // 3. Roll forward enough to be PAST `windowStart + BLOCK_WINDOW`.
        //    The next swap must reset windowStart to the new block.number
        //    and zero-base the new window's signedCum.
        vm.roll(uint256(wsAfterFirst) + uint256(blockWindow));
        router.swapExactInputSingle(key, true, 5e20, 1, address(this), block.timestamp + 100, "");
        (uint64 wsAfterReset, int128 cumAfterReset) = hook.poolWindow(pid);
        assertEq(uint256(wsAfterReset), block.number, "reset did not refresh windowStart");
        // The post-reset cum equals the just-fired swap's own delta —
        // strictly above the accumulated total of the prior window
        // (which was multiple swaps deep).
        assertGt(int256(cumAfterReset), int256(cumAfterFirst), "post-reset cum did not zero-base before accumulating");
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    /// @dev Reference value — same as every other test in the repo.
    function testWindowLength1MainnetReference() public {
        _checkWindowBehavior(1);
    }

    /// @dev Base-like: ~2 s block-time, so a multicall / Flashbots bundle
    ///      spans roughly six blocks. The hook's behavior must be
    ///      identical in shape to BLOCK_WINDOW=1, just with the reset
    ///      pushed out by five blocks.
    function testWindowLength6BaseLike() public {
        _checkWindowBehavior(6);
    }

    /// @dev Arbitrum-like: ~250 ms block-time. Same attack horizon
    ///      spans ~48 blocks. The deepest BLOCK_WINDOW Spry is meant
    ///      to ship at; if the lazy-reset arithmetic had an off-by-one
    ///      for large window values, this would catch it.
    function testWindowLength48ArbitrumLike() public {
        _checkWindowBehavior(48);
    }

    receive() external payable {}
}
