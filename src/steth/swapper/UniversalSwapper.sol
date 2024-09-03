// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISwapper} from "./ISwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";

/**
 * @title Swapper
 * @notice Contract facilitating token swaps on an arbitrary router.
 * @dev This contract is only meant to be used via delegatecalls from another contract.
 * @dev Using this contract directly for swaps will result in reverts.
 */
contract UniversalSwapper is ISwapper {
    /**
     * @notice Get the address of the swap router.
     * @return swapRouter Address of the contract acting as a central point for performing arbitrary token swaps.
     */
    function swapRouter() public pure virtual returns (address) {
        return C.LIFI;
    }

    /**
     * @notice Swap tokens using a preset swap router.
     * @param _tokenIn Address of the token to swap
     * @param _tokenOut Address of the token to receive
     * @param _amountIn Amount of the token to swap
     * @param _amountOutMin Minimum amount of the token to receive
     * @param _swapData Arbitrary data to pass to the swap router
     */
    function swapTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external virtual returns (uint256) {
        return SwapperLib._zeroExSwap(swapRouter(), _tokenIn, _tokenOut, _amountIn, _amountOutMin, _swapData);
    }
}
