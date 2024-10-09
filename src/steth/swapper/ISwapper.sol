// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/**
 * @title ISwapper
 * @notice Interface for a token swapper contract.
 */
interface ISwapper {
    /**
     * @notice Returns the address of the swap router used by the swapper.
     * @return The address of the swap router.
     */
    function swapRouter() external view returns (address);

    /**
     * @notice Swaps tokens using the swapper's router.
     * @param _tokenIn The address of the token to swap from.
     * @param _tokenOut The address of the token to swap to.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of `_tokenOut` to receive.
     * @param _swapData Arbitrary data required by the swap router.
     * @return The amount of `_tokenOut` received from the swap.
     */
    function swapTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external returns (uint256);
}
