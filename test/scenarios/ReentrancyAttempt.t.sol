// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title ReentrancyAttempt
/// @notice Hostile-token scenario. Deploys an ERC20 whose _transfer hook
///         re-enters the SpryRouter trying to start a new swap. The V4
///         PoolManager keeps a transient-storage `unlocked` flag for the
///         duration of an unlock callback; any nested unlock() must
///         revert with `AlreadyUnlocked`. This test confirms the guard
///         fires through the token-callback path.
contract ReentrancyAttempt is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
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
    }

    function testReentrantTokenCannotNestUnlock() public {
        ReentrantToken hostile = new ReentrantToken();
        ERC20Mint sane = new ERC20Mint();

        // Sort currencies canonically.
        (address t0, address t1) = address(hostile) < address(sane)
            ? (address(hostile), address(sane))
            : (address(sane), address(hostile));

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(k, 1 << 96);

        hostile.mint(address(this), 1e30);
        sane.mint(address(this), 1e30);
        hostile.approve(address(router), type(uint256).max);
        hostile.approve(address(lp),     type(uint256).max);
        sane.approve(address(router), type(uint256).max);
        sane.approve(address(lp),     type(uint256).max);

        // Add liquidity (hostile token's callback is not yet armed).
        lp.addLiquidity(k, 1e22, 1e22, address(this));

        // Arm the hostile token to re-enter on its next _transfer call.
        hostile.arm(router, k);

        // A swap that pulls hostile from msg.sender into the router will
        // trigger the callback, which calls router.swapExactInputSingle
        // again. Whether or not the inner call lands, the V4 lock must
        // prevent any nested state change and the outer call must revert.
        vm.expectRevert();
        router.swapExactInputSingle(
            k,
            address(hostile) == t0, // sell hostile if it's currency0
            1e18,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");
    }

    receive() external payable {}
}

contract ERC20Mint is ERC20 {
    constructor() ERC20("Mint", "MINT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract ReentrantToken is ERC20 {
    SpryRouter public router;
    PoolKey internal key;
    bool internal armed;

    constructor() ERC20("RE", "RE") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function arm(SpryRouter r, PoolKey memory k) external {
        router = r;
        key = k;
        armed = true;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (armed && address(router) != address(0)) {
            // Disarm to avoid infinite recursion in case the inner call
            // somehow doesn't revert. Then try to nest a swap.
            armed = false;
            router.swapExactInputSingle(
                key,
                true,
                1,
                1,
                address(this),
                block.timestamp + 100
            ,
            "");
        }
    }
}
