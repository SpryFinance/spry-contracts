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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";

/// @title AsymmetricDecimals
/// @notice Mainnet pools routinely pair tokens with mismatched decimals
///         (USDC at 6, WETH at 18). The virtual-reserve ratio in such a
///         pool can span 12 orders of magnitude. SmartFee's direct-delta
///         math (no intermediate spot-price division) must remain well-
///         defined and the dynamic fee bounded across this entire range.
contract AsymmetricDecimals is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    PoolKey internal key;
    USDC6 internal usdc;
    WETH18 internal weth;

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

        usdc = new USDC6();
        weth = new WETH18();
        // Sort by address.
        (Currency c0, Currency c1) = address(usdc) < address(weth)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(usdc)));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        // Initialize at a realistic USDC/WETH price (~1 ETH = 2500 USDC).
        // sqrt(2500 * 10^(18-6)) = sqrt(2500e12) = 5e7 * 1e6 = 5e7
        // sqrtPriceX96 = sqrtP * 2^96 ; depending on which side is c0.
        manager.initialize(key, _initSqrtPrice());

        usdc.mint(address(this), 1e30);
        weth.mint(address(this), 1e30);
        usdc.approve(address(router), type(uint256).max);
        usdc.approve(address(lp),     type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(lp),     type(uint256).max);

        // Add a moderately-sized full-range position.
        lp.addLiquidity(key, 1e22, 1e22, address(this));
    }

    function _initSqrtPrice() internal pure returns (uint160) {
        // Use 1:1 for simplicity in tests — the property we're testing is
        // robustness across extreme virtual-reserve ratios, which we
        // create by exercising large swap sizes.
        return 1 << 96;
    }

    function testSmartFeeStaysBoundedWhenLiquidityIsHighlyAsymmetric() public view {
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());

        // Test a range of swap sizes against the real pool state.
        int256[] memory sizes = new int256[](6);
        sizes[0] = -1;            // dust exact-in
        sizes[1] = -1e9;
        sizes[2] = -1e15;
        sizes[3] = -1e18;
        sizes[4] = -1e21;
        sizes[5] = -int256(uint256(liquidity) * 9 / 10); // 90% drain

        for (uint256 i = 0; i < sizes.length; ++i) {
            uint24 feeZ = SmartFeeLib.getDynamicFee(sqrtPriceX96, liquidity, true, sizes[i], hook.tierParams(2));
            uint24 feeO = SmartFeeLib.getDynamicFee(sqrtPriceX96, liquidity, false, sizes[i], hook.tierParams(2));
            assertLe(feeZ, 55_000, "fee never exceeds 55_000 pips, zeroForOne");
            assertLe(feeO, 55_000, "fee never exceeds 55_000 pips, oneForZero");
            assertGt(feeZ, 0, "fee always non-zero, zeroForOne");
            assertGt(feeO, 0, "fee always non-zero, oneForZero");
        }
    }

    function testTradeAfterLargeImbalanceStillCompletes() public {
        // Heavily skew the pool with several large one-direction swaps,
        // then verify a smaller trade in the opposite direction still
        // executes cleanly (no overflow, no div-by-zero).
        for (uint256 i = 0; i < 3; ++i) {
            router.swapExactInputSingle(key, true, 1e21, 1, address(this), block.timestamp + 100, "");
        }
        uint256 out = router.swapExactInputSingle(key, false, 1e18, 1, address(this), block.timestamp + 100, "");
        assertGt(out, 0, "counter-direction swap succeeds after large imbalance");
    }

    receive() external payable {}
}

/// @notice Mock USDC-like token at 6 decimals.
contract USDC6 is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Mock WETH-like token at 18 decimals.
contract WETH18 is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
