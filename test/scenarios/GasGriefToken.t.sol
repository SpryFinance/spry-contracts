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

/// @title GasGriefToken
/// @notice A pool that pairs with a malicious token whose transfer burns
///         a large amount of gas (e.g. unbounded storage writes). The
///         property we want: that pool's operations may run expensive or
///         out-of-gas, but the failure stays *local* to that pool — other
///         pools on the same PoolManager continue to operate normally.
///         This protects users of well-behaved pools from being denied
///         service by a malicious token's pool sharing infrastructure.
contract GasGriefToken is Test {
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
        require(address(hook) == predicted);
    }

    function testGasGriefingTokenCannotBlockUnrelatedPool() public {
        // Pool A pairs a gas-griefing token with a healthy one.
        GasGuzzler bad = new GasGuzzler();
        ERC20Mock good1 = new ERC20Mock();
        (address t0a, address t1a) = address(bad) < address(good1)
            ? (address(bad), address(good1))
            : (address(good1), address(bad));
        PoolKey memory keyBad = PoolKey({
            currency0: Currency.wrap(t0a),
            currency1: Currency.wrap(t1a),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyBad, 1 << 96);

        // Pool B is entirely unrelated.
        ERC20Mock good2 = new ERC20Mock();
        ERC20Mock good3 = new ERC20Mock();
        (address t0b, address t1b) = address(good2) < address(good3)
            ? (address(good2), address(good3))
            : (address(good3), address(good2));
        PoolKey memory keyGood = PoolKey({
            currency0: Currency.wrap(t0b),
            currency1: Currency.wrap(t1b),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyGood, 1 << 96);

        bad.mint(address(this), 1e30);
        deal(address(good1), address(this), 1e30);
        deal(address(good2), address(this), 1e30);
        deal(address(good3), address(this), 1e30);
        bad.approve(address(router), type(uint256).max);
        bad.approve(address(lp),     type(uint256).max);
        good1.approve(address(router), type(uint256).max);
        good1.approve(address(lp),     type(uint256).max);
        good2.approve(address(router), type(uint256).max);
        good2.approve(address(lp),     type(uint256).max);
        good3.approve(address(router), type(uint256).max);
        good3.approve(address(lp),     type(uint256).max);

        // Operating on pool B (the healthy one) works fine, even though
        // pool A's token would burn gas if invoked. The shared PoolManager
        // does not share fate across pools.
        (uint128 liqB, , ) = lp.addLiquidity(keyGood, 1e22, 1e22, address(this));
        assertGt(liqB, 0, "healthy pool add works");

        bool zfo = t0b == address(good2);
        uint256 out = router.swapExactInputSingle(
            keyGood, zfo, 1e18, 1, address(this), block.timestamp + 100
        ,
        "");
        assertGt(out, 0, "healthy pool swap works");

        // Now try pool A with a limited gas budget. We don't care whether
        // the call reverts or simply runs out of gas — the assertion is
        // that pool B keeps working AFTER pool A's failure.
        try lp.addLiquidity{gas: 5_000_000}(keyBad, 1e22, 1e22, address(this)) returns (uint128, uint256, uint256) {} catch {}

        // Pool B is still usable.
        uint256 out2 = router.swapExactInputSingle(
            keyGood, zfo, 1e17, 1, address(this), block.timestamp + 100
        ,
        "");
        assertGt(out2, 0, "healthy pool swap still works after bad pool's attempt");
    }
}

/// @notice ERC20 that intentionally consumes huge gas in every transfer
///         via repeated storage writes to fresh slots.
contract GasGuzzler is ERC20 {
    mapping(uint256 => uint256) internal sink;
    uint256 internal nonce;

    constructor() ERC20("Guzzle", "GUZ") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        // Burn gas with many cold storage writes.
        uint256 n = nonce;
        for (uint256 i = 0; i < 200; ++i) {
            sink[n + i] = block.timestamp + i;
        }
        nonce = n + 200;
    }
}
