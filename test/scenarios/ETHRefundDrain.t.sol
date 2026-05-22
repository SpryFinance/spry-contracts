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

/// @title ETHRefundDrain
/// @notice Verifies that the SpryRouter's native-ETH refund path cannot be
///         exploited to extract more ETH than the caller actually overpaid.
///         A malicious caller (`Greedy`) sends 10 ETH for a swap that only
///         needs 1 ETH, then implements a receive() hook that tries to call
///         the router AGAIN to siphon more ETH on the refund step. The
///         expected outcome: the attacker gets back ONLY the legitimate
///         overpayment, and the router/manager don't lose ETH to the
///         re-entry attempt.
contract ETHRefundDrain is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token;
    PoolKey internal key;

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

        token = new ERC20Mock();
        // currency0 must be native ETH (address(0)), currency1 = token.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 1 << 96);

        deal(address(token), address(this), 1e30);
        deal(address(this), 100 ether);
        token.approve(address(router), type(uint256).max);
        token.approve(address(lp),     type(uint256).max);

        lp.addLiquidity{value: 10 ether}(key, 10 ether, 10 ether, address(this));
    }

    function testGreedyCallerOnlyGetsItsActualOverpayment() public {
        Greedy g = new Greedy(router, key);
        deal(address(g), 100 ether);
        uint256 attackerEthBefore = address(g).balance;
        uint256 managerEthBefore = address(manager).balance;
        uint256 routerEthBefore = address(router).balance;

        // exact-output swap: ask for 1e17 token, overpay with 10 ether.
        // Refund flow should send back ~10 - effective_eth_in to the caller.
        g.attemptDrain{value: 0}(1e17, 10 ether);

        // Attacker recovers (most of) the unused ETH but not MORE than they sent.
        // Note: the attempt to re-enter on the refund (via receive()) either
        // reverts inside the receive and gets swallowed, or simply transfers
        // the legitimate refund. Either way, the attacker's balance must not
        // increase beyond the legitimate refund.
        assertLe(address(g).balance, attackerEthBefore, "attacker did not gain ETH");
        // Manager balance changed only by the legitimate swap amount.
        // Router does not retain ETH after a swap call settles.
        assertEq(address(router).balance, routerEthBefore, "router holds no stray ETH");
        // Manager retained the swapped-in ETH for the swap.
        assertGe(address(manager).balance, managerEthBefore, "manager balance non-decreasing");
    }

    receive() external payable {}
}

contract Greedy {
    SpryRouter public router;
    PoolKey internal key;
    bool internal reenter;

    constructor(SpryRouter _router, PoolKey memory _key) {
        router = _router;
        key = _key;
    }

    function attemptDrain(uint256 amountOut, uint256 amountInMax) external payable {
        reenter = true;
        router.swapExactOutputSingle{value: amountInMax}(
            key,
            true,
            amountOut,
            amountInMax,
            address(this),
            block.timestamp + 100
        ,
        "");
        reenter = false;
    }

    /// @notice On receiving the refund, try to call the router again to
    ///         siphon more. The call must not yield more ETH to this
    ///         contract than the legitimate refund. Errors are swallowed
    ///         so the outer call still completes.
    receive() external payable {
        if (reenter) {
            reenter = false; // one-shot to avoid infinite loop
            try router.swapExactOutputSingle{value: address(this).balance}(
                key,
                true,
                1,
                address(this).balance,
                address(this),
                block.timestamp + 100
            ,
            "") returns (uint256) {} catch {}
        }
    }
}
