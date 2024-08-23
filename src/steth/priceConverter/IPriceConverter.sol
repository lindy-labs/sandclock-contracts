// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/// @title Price Converter Interface
/// @notice An empty placeholder interface for price converter contracts
interface IPriceConverter {}

interface IScETHPriceConverter is IPriceConverter {
    function ethToWstEth(uint256 ethAmount) external view returns (uint256);

    function stEthToEth(uint256 _stEthAmount) external view returns (uint256);

    function wstEthToEth(uint256 wstEthAmount) external view returns (uint256);
}

interface ISinglePairPriceConverter is IPriceConverter {
    function tokenToBaseAsset(uint256 _tokenAmount) external view returns (uint256 assetAmount);

    function baseAssetToToken(uint256 _assetAmount) external view returns (uint256 tokenAmount);
}