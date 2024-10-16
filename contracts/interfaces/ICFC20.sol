// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ICFC20Meta} from "./ICFC20Meta.sol";

interface ICFC20 is ICFC20Meta {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
