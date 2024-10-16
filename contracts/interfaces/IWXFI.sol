// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IWXFI {
    function deposit() external payable;

    function withdraw(uint256) external;

    function transfer(address to, uint256 value) external returns (bool);
}
