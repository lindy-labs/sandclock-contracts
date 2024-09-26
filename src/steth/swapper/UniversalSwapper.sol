// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISwapper} from "./ISwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";

/**
 * @title UniversalSwapper
 * @notice Contract facilitating token swaps using a preset swap router.
 * @dev This contract is intended to be used via delegatecalls from another contract.
 * @dev Using this contract directly for swaps may result in reverts.
 */
contract UniversalSwapper is ISwapper {
    /**
     * @notice Get the address of the swap router.
     * @return swapRouter The address of the swap router contract.
     */
    function swapRouter() public pure virtual returns (address) {
        return C.LIFI;
    }

    /**
     * @notice Swap tokens using the preset swap router.
     * @param _tokenIn The address of the token to swap from.
     * @param _tokenOut The address of the token to receive.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of `_tokenOut` to receive.
     * @param _swapData Arbitrary data to pass to the swap router.
     * @return amountReceived The amount of `_tokenOut` received from the swap.
     */
    function swapTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external virtual override returns (uint256 amountReceived) {
        amountReceived = SwapperLib._swapTokens(swapRouter(), _tokenIn, _tokenOut, _amountIn, _amountOutMin, _swapData);
    }
}
