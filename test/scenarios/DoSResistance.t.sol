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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title DoSResistance
/// @notice Denial-of-service scenarios. Confirms that bad behavior on a
///         single token or pool cannot brick the protocol globally.
///           1. A token that ALWAYS reverts on transfer. Its pool's swaps
///              fail (expected), but a healthy second pool keeps working.
///           2. A pool with `address(0)` as a hooks key falls back to
///              static fee — not a Spry pool — and still works as a
///              normal V4 pool, demonstrating that the hook only governs
///              pools it's actually attached to.
contract DoSResistance is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

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
    }

    function testBadTokenPoolCannotBlockOtherPools() public {
        BadToken bad = new BadToken();
        ERC20Mock good = new ERC20Mock();
        ERC20Mock good2 = new ERC20Mock();

        // Pool 1: bad / good
        (address t0a, address t1a) = address(bad) < address(good)
            ? (address(bad), address(good))
            : (address(good), address(bad));
        PoolKey memory keyBad = PoolKey({
            currency0: Currency.wrap(t0a),
            currency1: Currency.wrap(t1a),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyBad, 1 << 96);

        // Pool 2: good / good2 (independent)
        (address t0b, address t1b) = address(good) < address(good2)
            ? (address(good), address(good2))
            : (address(good2), address(good));
        PoolKey memory keyGood = PoolKey({
            currency0: Currency.wrap(t0b),
            currency1: Currency.wrap(t1b),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyGood, 1 << 96);

        // Provision the test contract with all three tokens + approvals.
        bad.mint(address(this), 1e30);
        deal(address(good), address(this), 1e30);
        deal(address(good2), address(this), 1e30);
        bad.approve(address(router), type(uint256).max);
        bad.approve(address(lp),     type(uint256).max);
        good.approve(address(router), type(uint256).max);
        good.approve(address(lp),     type(uint256).max);
        good2.approve(address(router), type(uint256).max);
        good2.approve(address(lp),     type(uint256).max);

        // Pool 1 add liquidity will fail because bad token reverts on transfer.
        vm.expectRevert();
        lp.addLiquidity(keyBad, 1e22, 1e22, address(this));

        // Pool 2 still works perfectly. This is the property we care about.
        (uint128 liq,,) = lp.addLiquidity(keyGood, 1e22, 1e22, address(this));
        assertGt(liq, 0, "healthy pool unaffected by bad-token pool failure");

        uint256 outBefore = good2.balanceOf(address(this));
        bool zfo = address(good) < address(good2);
        router.swapExactInputSingle(keyGood, zfo, 1e18, 1, address(this), block.timestamp + 100, "");
        // One side moved (we don't care which without checking direction explicitly).
        // What matters: the swap completes.
        assertTrue(
            good2.balanceOf(address(this)) != outBefore
                || good.balanceOf(address(this)) != 1e30,
            "swap on healthy pool completed"
        );
    }

    function testStaticFeePoolWorksInParallel() public {
        // A non-Spry pool with no hook and a vanilla 3000-pip static fee
        // initialized on the same PoolManager works alongside Spry pools.
        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (ERC20Mock t0, ERC20Mock t1) = address(a) < address(b) ? (a, b) : (b, a);

        PoolKey memory vanillaKey = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(vanillaKey, 1 << 96);

        deal(address(t0), address(this), 1e30);
        deal(address(t1), address(this), 1e30);
        t0.approve(address(router), type(uint256).max);
        t0.approve(address(lp),     type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        t1.approve(address(lp),     type(uint256).max);

        (uint128 liq,,) = lp.addLiquidity(vanillaKey, 1e22, 1e22, address(this));
        assertGt(liq, 0);

        uint256 out = router.swapExactInputSingle(
            vanillaKey, true, 1e18, 1, address(this), block.timestamp + 100
        ,
        "");
        assertGt(out, 0, "vanilla pool swap works alongside Spry pools");
    }

    receive() external payable {}
}

/// @notice ERC20 that reverts on every external transfer attempt. Mints
///         succeed because OZ v4.9's _mint() does not route through
///         _transfer, so we can still seed balances.
contract BadToken is ERC20 {
    constructor() ERC20("Bad", "BAD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function _transfer(address, address, uint256) internal pure override {
        revert("BadToken: transfers disabled");
    }
}
