// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {ISwapper} from "./ISwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";

/**
 * @title Swapper
 * @notice Contract facilitating token swaps on Uniswap V3 and 0x.
 * @dev This contract is only meant to be used via delegatecalls from another contract.
 * @dev Using this contract directly for swaps might result in reverts.
 */
contract ZeroXSwapper is ISwapper {
    using SafeTransferLib for ERC20;

    /**
     * @notice Swap tokens on 0xswap.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     * @param _swapData Encoded swap data obtained from 0x API.
     * @return Amount of the token received.
     */
    function zeroExSwap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external returns (uint256) {
        return SwapperLib._zeroExSwap(_tokenIn, _tokenOut, _amountIn, _amountOutMin, _swapData);
    }
}
