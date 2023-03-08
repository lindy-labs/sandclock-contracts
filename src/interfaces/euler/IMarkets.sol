// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface IMarkets {
    struct AssetConfig {
        address eTokenAddress;
        bool borrowIsolated;
        uint32 collateralFactor;
        uint32 borrowFactor;
        uint24 twapWindow;
    }

    /// @notice Add an asset to the entered market list, or do nothing if already entered
    /// @param subAccountId 0 for primary, 1-255 for a sub-account
    /// @param newMarket Underlying token address
    function enterMarket(uint256 subAccountId, address newMarket) external;

    function underlyingToAssetConfig(address underlying) external view returns (AssetConfig memory);
}
