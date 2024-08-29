// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {AmountReceivedBelowMin} from "../../errors/scErrors.sol";
import {ISwapRouter} from "../../interfaces/uniswap/ISwapRouter.sol";
import {ILido} from "../../interfaces/lido/ILido.sol";
import {IwstETH} from "../../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../../interfaces/curve/ICurvePool.sol";
import {IScWETHSwapper} from "./../swapper/ISwapper.sol";

library SwapperLib {
    using SafeTransferLib for ERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    ICurvePool public constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);

    WETH public constant weth = WETH(payable(C.WETH));
    ILido public constant stEth = ILido(C.STETH);
    IwstETH public constant wstEth = IwstETH(C.WSTETH);

    /**
     * @notice Swap tokens on Uniswap V3 using exact input single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     * @param _poolFee Pool fee of the Uniswap V3 pool.
     * @return Amount of the token received.
     */
    function _uniswapSwapExactInput(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint24 _poolFee
    ) internal returns (uint256) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin,
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact input multi route
     * @param _tokenIn Address of the token to swap
     * @param _amountIn Amount of the token to swap
     * @param _amountOutMin Minimum amount of the token to receive
     * @param _path abi.encodePacked(_tokenIn, fees, ...middleTokens, ...fees, _tokenOut)
     */
    function _uniswapSwapExactInputMultihop(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path
    ) internal returns (uint256) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: _path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin
        });

        return swapRouter.exactInput(params);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output multi route
     * @param _tokenIn Address of the token to swap
     * @param _amountOut Amount of the token to receive
     * @param _amountInMaximum Maximum amount of the token to swap
     * @param _path abi.encodePacked(_tokenOut, fees, ...middleTokens, ...fees, _tokenIn)
     */
    function _uniswapSwapExactOutputMultihop(
        address _tokenIn,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        bytes memory _path
    ) internal returns (uint256) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountInMaximum);

        ISwapRouter.ExactOutputParams memory params = ISwapRouter.ExactOutputParams({
            path: _path,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _amountOut,
            amountInMaximum: _amountInMaximum
        });

        return swapRouter.exactOutput(params);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountOut Amount of the token to receive.
     * @param _amountInMaximum Maximum amount of the token to swap.
     * @param _poolFee Pool fee of the Uniswap V3 pool.
     * @return Amount of the token swapped.
     */
    function _uniswapSwapExactOutput(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint24 _poolFee
    ) internal returns (uint256) {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _poolFee,
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
}
