// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRewardsController {
    function claimAllRewardsToSelf(address[] calldata assets)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}
