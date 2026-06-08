// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RevokeApprovals
/// @notice Testnet helper. Sets a token's ERC20 allowance back to 0 for the
///         Spry spenders the other scripts approve (SpryRouter for swaps and
///         PoolModifyLiquidityTest for LP seeding), or for a single explicit
///         spender if SPENDER is given.
///
/// @dev Reads from env:
///        PRIVATE_KEY  owner key (the allowance granter)
///        TOKEN        the ERC20 to revoke
///      Optional:
///        SPENDER      revoke only this spender; if unset, revokes
///                     SPRY_ROUTER_ADDRESS and V4_POOL_MODIFY_LIQUIDITY_TEST
///
/// @dev This revokes plain ERC20 allowances (what the swap/seed scripts set).
///      Permit2 allowances are a separate mechanism; to clear one, pass the
///      Permit2 contract as SPENDER only if you previously approved it here.
///
/// Example:
///   TOKEN=0x.. forge script script/RevokeApprovals.s.sol:RevokeApprovals \
///     --rpc-url base_sepolia --broadcast
contract RevokeApprovals is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address token = vm.envAddress("TOKEN");
        address explicitSpender = vm.envOr("SPENDER", address(0));

        vm.startBroadcast(pk);
        if (explicitSpender != address(0)) {
            _revoke(token, me, explicitSpender);
        } else {
            _revoke(token, me, vm.envOr("SPRY_ROUTER_ADDRESS", address(0)));
            _revoke(token, me, vm.envOr("V4_POOL_MODIFY_LIQUIDITY_TEST", address(0)));
        }
        vm.stopBroadcast();
    }

    function _revoke(address token, address owner, address spender) internal {
        if (spender == address(0)) return;
        uint256 current = IERC20(token).allowance(owner, spender);
        if (current == 0) {
            console.log("already 0, skipped spender:", spender);
            return;
        }
        IERC20(token).approve(spender, 0);
        console.log("revoked spender:", spender);
        console.log("  previous allowance:", current);
    }
}
