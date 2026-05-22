// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title FirstMintInflation
/// @notice The classic "first depositor inflates LP-share value" attack on
///         AMMs. The attacker mints a tiny LP position to seed the pool,
///         then donates a large amount directly to the pool's accounting
///         to skew share-to-token ratio. A second honest LP joining now
///         risks getting rounded down to zero shares.
///         V4 pools compute LP shares from sqrtPrice math (not from a
///         supply ratio), so the attack has no traction at the PoolManager
///         level. This scenario asserts that property holds end-to-end via
///         the SpryRouter.
contract FirstMintInflation is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    PoolKey internal key;

    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 1 << 96);

        deal(address(token0), attacker, 1e30);
        deal(address(token1), attacker, 1e30);
        deal(address(token0), victim, 1e30);
        deal(address(token1), victim, 1e30);
        vm.startPrank(attacker);
        token0.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        vm.stopPrank();
        vm.startPrank(victim);
        token0.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        vm.stopPrank();
    }

    function testHonestLPGetsReasonableSharesAfterAttackerSeeds() public {
        // Attacker is the very first depositor; tries to mint the smallest
        // possible position so a single direct donation skews share value.
        vm.prank(attacker);
        (uint128 attackerLiq, , ) = lp.addLiquidity(key, 1001, 1001, attacker);
        assertGt(attackerLiq, 0, "attacker minted dust position");

        // Attacker donates a huge amount of token0 directly into the
        // PoolManager. This neither moves the pool's sqrtPriceX96 nor its
        // liquidity (settlements are required for accounting), but a
        // share-supply-based AMM would conflate this donation with growth.
        vm.prank(attacker);
        token0.transfer(address(manager), 1e22);

        // Honest LP joins with a normal-sized deposit.
        vm.prank(victim);
        (uint128 victimLiq, uint256 v0, uint256 v1) = lp.addLiquidity(key, 1e18, 1e18, victim);

        // Victim received a meaningful, non-rounded-to-zero LP position.
        // The exact value depends on getLiquidityForAmounts at the current
        // sqrtPriceX96, but it must be of the same order as the input.
        assertGt(victimLiq, 1e15, "victim got a reasonable share count");
        assertGt(v0, 0, "victim consumed some token0");
        assertGt(v1, 0, "victim consumed some token1");
    }
}
