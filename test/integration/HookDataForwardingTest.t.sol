// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LPHelper} from "../utils/LPHelper.sol";

/// @title HookDataForwardingTest
/// @notice Proves that the bytes `hookData` parameter passed to the
///         router's single-hop swap entry points actually reaches the
///         pool's hook's `beforeSwap`. The default SpryHook ignores
///         hookData, so we deploy a purpose-built `RecorderHook` that
///         emits an event containing the received payload — we then
///         match that event against what we sent.
contract HookDataForwardingTest is Test {
    IPoolManager internal manager;
    RecorderHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    PoolKey internal key;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    event HookDataSeen(bytes hookData);

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(RecorderHook).creationCode,
            abi.encode(manager)
        );
        hook = new RecorderHook{salt: salt}(manager);
        require(address(hook) == predicted, "hook addr mismatch");

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);

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

    // ---------------------------------------------------------------------
    // 1. Default empty hookData is forwarded as empty bytes.
    // ---------------------------------------------------------------------
    function testEmptyHookDataIsForwarded() public {
        vm.recordLogs();
        router.swapExactInputSingle(
            key, true, 1e18, 1, address(this), block.timestamp + 100, ""
        );

        bytes memory seen = _readLastHookDataEvent();
        assertEq(seen.length, 0, "hook saw empty hookData");
    }

    // ---------------------------------------------------------------------
    // 2. Arbitrary hookData reaches the hook unmodified.
    // ---------------------------------------------------------------------
    function testArbitraryHookDataIsForwarded() public {
        bytes memory payload = abi.encode(uint256(42), address(0xC0FFEE), "spry-referral");

        vm.recordLogs();
        router.swapExactInputSingle(
            key, true, 1e18, 1, address(this), block.timestamp + 100, payload
        );

        bytes memory seen = _readLastHookDataEvent();
        assertEq(seen, payload, "hook saw the exact payload we sent");
    }

    // ---------------------------------------------------------------------
    // 3. Exact-output single also forwards hookData.
    // ---------------------------------------------------------------------
    function testExactOutputSingleForwardsHookData() public {
        bytes memory payload = hex"deadbeef";

        vm.recordLogs();
        router.swapExactOutputSingle(
            key, true, 1e17, type(uint256).max, address(this), block.timestamp + 100, payload
        );

        bytes memory seen = _readLastHookDataEvent();
        assertEq(seen, payload, "exact-output forwarded hookData unchanged");
    }

    // ---------------------------------------------------------------------
    // 4. Large hookData (>1 KiB) survives encoding/decoding.
    // ---------------------------------------------------------------------
    function testLargeHookDataSurvivesRoundTrip() public {
        // 1 KiB of arbitrary bytes.
        bytes memory big = new bytes(1024);
        for (uint256 i; i < big.length; ++i) {
            big[i] = bytes1(uint8(i & 0xff));
        }

        vm.recordLogs();
        router.swapExactInputSingle(
            key, true, 1e16, 1, address(this), block.timestamp + 100, big
        );

        bytes memory seen = _readLastHookDataEvent();
        assertEq(keccak256(seen), keccak256(big), "1 KiB payload survived round-trip");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _readLastHookDataEvent() internal returns (bytes memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("HookDataSeen(bytes)");
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory L = logs[i - 1];
            if (L.emitter == address(hook) && L.topics.length > 0 && L.topics[0] == sig) {
                return abi.decode(L.data, (bytes));
            }
        }
        revert("no HookDataSeen event observed");
    }
}

/// @notice A minimal hook that emits the hookData it receives in
///         `beforeSwap`. All other IHooks entry points are no-ops, so
///         pool initialization and liquidity ops work transparently.
contract RecorderHook is IHooks {
    IPoolManager internal immutable POOL_MANAGER;

    event HookDataSeen(bytes hookData);

    constructor(IPoolManager _manager) {
        POOL_MANAGER = _manager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(POOL_MANAGER), "not pool manager");
        _;
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        emit HookDataSeen(hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external view onlyPoolManager returns (bytes4) { return IHooks.afterInitialize.selector; }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4) { return IHooks.beforeAddLiquidity.selector; }

    function afterAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4) { return IHooks.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external view onlyPoolManager returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view onlyPoolManager returns (bytes4) { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view onlyPoolManager returns (bytes4) { return IHooks.afterDonate.selector; }
}
