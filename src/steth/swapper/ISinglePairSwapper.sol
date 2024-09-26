// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "./ISwapper.sol";

/**
 * @title ISinglePairSwapper
 * @notice Interface for a swapper handling swaps between a specific asset and target token pair.
 */
interface ISinglePairSwapper is ISwapper {
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
     * @notice Swaps the target token for the asset.
     * @param _targetAmount The amount of the target token to swap.
     * @param _assetAmountOutMin The minimum amount of the asset to receive.
     * @return amountReceived The amount of the asset received from the swap.
     */
    function swapTargetTokenForAsset(uint256 _targetAmount, uint256 _assetAmountOutMin)
        external
        returns (uint256 amountReceived);

    /**
     * @notice Swaps the asset for an exact amount of the target token.
     * @param _targetTokenAmountOut The exact amount of the target token desired.
     * @return amountSpent The amount of the asset spent to receive the target token.
     */
    function swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) external returns (uint256 amountSpent);
}
