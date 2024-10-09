// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IPriceConverter} from "./IPriceConverter.sol";

/**
 * @title Single Pair Price Converter Interface
 * @notice Interface for price conversion between a specific asset and target token pair.
 */
interface ISinglePairPriceConverter is IPriceConverter {
    /**
     * @notice Returns the address of the asset token.
     * @return The address of the asset token.
     */
    function asset() external view returns (address);

    /**
     * @notice Returns the address of the target token.
     * @return The address of the target token.
     */
    function targetToken() external view returns (address);

    /**
     * @notice Converts an amount of target token to the equivalent amount of asset.
     * @param _tokenAmount The amount of target token to convert.
     * @return assetAmount The equivalent amount of the asset.
     */
    function targetTokenToAsset(uint256 _tokenAmount) external view returns (uint256 assetAmount);

    /**
     * @notice Converts an amount of asset to the equivalent amount of target token.
     * @param _assetAmount The amount of asset to convert.
     * @return tokenAmount The equivalent amount of the target token.
     */
    function assetToTargetToken(uint256 _assetAmount) external view returns (uint256 tokenAmount);
}
