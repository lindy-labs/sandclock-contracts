// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface IMarkets {
    /// @notice Add an asset to the entered market list, or do nothing if already entered
    /// @param subAccountId 0 for primary, 1-255 for a sub-account
    /// @param newMarket Underlying token address
    function enterMarket(uint256 subAccountId, address newMarket) external;
}
