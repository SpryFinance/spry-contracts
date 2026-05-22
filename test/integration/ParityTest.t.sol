// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
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

/// @title ParityTest
/// @notice Edge-case coverage for the surface the single / multi / liquidity
///         suites don't reach: native-ETH pools (currency0 = address(0))
///         end-to-end, multi-pool isolation via distinct PoolKeys, the
///         PoolManager's own transient-storage re-entry lock, and a few
///         router error paths.
contract ParityTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    ERC20Mock internal tokenC;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        tokenC = new ERC20Mock();

        deal(address(tokenA), address(this), 1e30);
        deal(address(tokenB), address(this), 1e30);
        deal(address(tokenC), address(this), 1e30);
        deal(address(this), 1000 ether);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);
    }

    function _sortPair(ERC20Mock a, ERC20Mock b) internal pure returns (Currency c0, Currency c1) {
        if (address(a) < address(b)) {
            return (Currency.wrap(address(a)), Currency.wrap(address(b)));
        }
        return (Currency.wrap(address(b)), Currency.wrap(address(a)));
    }

    function _keyERC20Pair(ERC20Mock a, ERC20Mock b) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = _sortPair(a, b);
        return PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    // ---------------------------------------------------------------------
    // Native-ETH pool: currency0 = address(0)
    // ---------------------------------------------------------------------

    function testNativeETHPoolAddLiquidityAndSwap() public {
        // currency0 must be address(0) since 0x000... < every ERC20 address.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        lp.addLiquidity{value: 10 ether}(key, 10 ether, 10 ether, address(this));

        uint256 ethBefore = address(this).balance;
        uint256 tokABefore = tokenA.balanceOf(address(this));

        // Swap 1 ETH -> tokenA
        uint256 out = router.swapExactInputSingle{value: 1 ether}(
            key,
            true,
            1 ether,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");

        assertGt(out, 0, "received tokenA from native ETH swap");
        assertEq(tokenA.balanceOf(address(this)) - tokABefore, out, "tokenA delta matches return value");
        assertEq(ethBefore - address(this).balance, 1 ether, "spent exactly 1 ETH");
    }

    // ---------------------------------------------------------------------
    // Multi-pool isolation
    // ---------------------------------------------------------------------

    function testMultiPoolIsolation() public {
        PoolKey memory keyAB = _keyERC20Pair(tokenA, tokenB);
        PoolKey memory keyAC = _keyERC20Pair(tokenA, tokenC);
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyAC, SQRT_PRICE_1_1);

        lp.addLiquidity(keyAB, 1e21, 1e21, address(this));
        lp.addLiquidity(keyAC, 1e21, 1e21, address(this));

        (uint160 priceAB_pre, , , ) = manager.getSlot0(keyAB.toId());
        (uint160 priceAC_pre, , , ) = manager.getSlot0(keyAC.toId());
        uint128 liqAC_pre = manager.getLiquidity(keyAC.toId());

        bool zeroForOneAB = address(tokenA) < address(tokenB);
        router.swapExactInputSingle(
            keyAB,
            zeroForOneAB,
            1e19,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");

        (uint160 priceAB_post, , , ) = manager.getSlot0(keyAB.toId());
        (uint160 priceAC_post, , , ) = manager.getSlot0(keyAC.toId());
        uint128 liqAC_post = manager.getLiquidity(keyAC.toId());

        assertTrue(priceAB_post != priceAB_pre, "pool AB price moved");
        assertEq(priceAC_post, priceAC_pre, "pool AC price unchanged");
        assertEq(liqAC_post, liqAC_pre, "pool AC liquidity unchanged");

        // LP positions are isolated by (poolId, owner) — V4 stores them
        // under distinct keys, so this contract has positive liquidity in
        // both pools but unrelated addresses have nothing.
        assertGt(lp.positionLiquidity(keyAB, address(this)), 0);
        assertGt(lp.positionLiquidity(keyAC, address(this)), 0);
        assertEq(lp.positionLiquidity(keyAB, address(0xdead)), 0);
    }

    // ---------------------------------------------------------------------
    // PoolManager re-entry lock
    // ---------------------------------------------------------------------

    function testManagerRejectsNestedUnlock() public {
        // Calling manager.unlock inside its own unlock-callback must revert.
        NestedUnlockAttempt attacker = new NestedUnlockAttempt(manager);
        vm.expectRevert();
        attacker.attack();
    }

    // ---------------------------------------------------------------------
    // Router error-path coverage that single/multi tests don't reach
    // ---------------------------------------------------------------------

    function testExactOutputSingleRevertsWhenAmountInMaxIsZero() public {
        PoolKey memory key = _keyERC20Pair(tokenA, tokenB);
        manager.initialize(key, SQRT_PRICE_1_1);
        lp.addLiquidity(key, 1e21, 1e21, address(this));

        vm.expectRevert(SpryRouter.ExcessiveInput.selector);
        router.swapExactOutputSingle(
            key,
            true,
            1e18,
            0,
            address(this),
            block.timestamp + 100
        ,
        "");
    }

    function testRouterReceivesETHFromPoolManager() public {
        // The router has a receive(). Direct ETH from EOA also lands here.
        // Verify it accepts a plain ETH transfer without reverting.
        (bool ok,) = address(router).call{value: 1}("");
        assertTrue(ok);
    }

    receive() external payable {}
}

/// @notice Helper that re-enters PoolManager.unlock from within its own
///         unlock callback. V4's Lock library uses transient storage and
///         must reject the nested call.
contract NestedUnlockAttempt is IUnlockCallback {
    IPoolManager public immutable MANAGER;
    bool internal nested;

    constructor(IPoolManager _manager) {
        MANAGER = _manager;
    }

    function attack() external {
        MANAGER.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(MANAGER));
        if (!nested) {
            nested = true;
            // Should revert with V4's already-unlocked guard.
            MANAGER.unlock("");
        }
        return "";
    }
}
