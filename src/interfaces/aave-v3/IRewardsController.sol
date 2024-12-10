// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);

    function getUserRewards(address[] calldata assets, address user, address reward) external view returns (uint256);
}
