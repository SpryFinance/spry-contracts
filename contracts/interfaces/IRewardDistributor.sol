// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IRewardDistributor {
    function withdraw(uint, uint, address, address) external view returns (uint256);

    function pendingReward(uint, address) external view returns (uint256);

}