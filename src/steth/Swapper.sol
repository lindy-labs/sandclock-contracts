// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {AmountReceivedBelowMin} from "../errors/scErrors.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {Constants as C} from "../lib/Constants.sol";

/**
 * @title Swapper
 * @notice Contract facilitating token swaps on Uniswap V3 and 0x.
 */
contract Swapper {
    using SafeTransferLib for ERC20;
    using Address for address;

    // Uniswap V3 router
    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    // 0x router address
    address public constant zeroExRouter = C.ZERO_EX_ROUTER;

    /**
     * @notice Swap tokens on Uniswap V3 using exact input single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     */
    function uniswapSwapExactInput(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOutMin)
        external
        returns (uint256)
    {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin,
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountOut Amount of the token to receive.
     * @param _amountInMaximum Maximum amount of the token to swap.
     */
    function uniswapSwapExactOutput(address _tokenIn, address _tokenOut, uint256 _amountOut, uint256 _amountInMaximum)
        external
        returns (uint256)
    {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _amountOut,
            amountInMaximum: _amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountInMaximum);

        uint256 amountIn = swapRouter.exactOutputSingle(params);

        ERC20(_tokenIn).safeApprove(address(swapRouter), 0);

        return amountIn;
    }

    /**
     * @notice Swap tokens on 0x protocol.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     * @param _swapData Encoded swap data obtained from 0x API.
     */
    function zeroExSwap(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external returns (uint256) {
        uint256 tokenOutInitialBalance = _tokenOut.balanceOf(address(this));

        _tokenIn.safeApprove(C.ZERO_EX_ROUTER, _amountIn);

        zeroExRouter.functionCall(_swapData);

        uint256 amountReceived = _tokenOut.balanceOf(address(this)) - tokenOutInitialBalance;

        if (amountReceived < _amountOutMin) revert AmountReceivedBelowMin();

        _tokenIn.approve(C.ZERO_EX_ROUTER, 0);

        return amountReceived;
    }
}
