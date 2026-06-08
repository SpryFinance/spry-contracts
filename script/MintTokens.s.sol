// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal handle to a MintableERC20 (the mock SeedPool deploys).
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title MintTokens
/// @notice Testnet helper. Mints a MintableERC20 (the mock deployed by
///         SeedPool) to any address. The mock's mint() is permissionless.
///
/// @dev Reads from env:
///        PRIVATE_KEY  caller key
///        TOKEN        the MintableERC20 address
///        TO           recipient of the minted tokens
///      Optional:
///        AMOUNT       amount to mint, in token base units (default 1e21)
///
/// Example:
///   TOKEN=0x.. TO=0x.. AMOUNT=1000000000000000000000 \
///     forge script script/MintTokens.s.sol:MintTokens --rpc-url base_sepolia --broadcast
contract MintTokens is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address token = vm.envAddress("TOKEN");
        address to = vm.envAddress("TO");
        uint256 amount = vm.envOr("AMOUNT", uint256(1e21));

        vm.startBroadcast(pk);
        IMintableERC20(token).mint(to, amount);
        vm.stopBroadcast();

        console.log("token:      ", token);
        console.log("minted to:  ", to);
        console.log("amount:     ", amount);
        console.log("new balance:", IERC20(token).balanceOf(to));
    }
}
