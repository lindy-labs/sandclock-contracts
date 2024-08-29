// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {AmountReceivedBelowMin} from "../errors/scErrors.sol";
import {Constants as C} from "../lib/Constants.sol";
import {IScWETHSwapper} from "./swapper/ISwapper.sol";
import {SwapperLib} from "./swapper/SwapperLib.sol";

/**
 * @title Swapper
 * @notice Contract facilitating token swaps on Uniswap V3 and 0x.
 * @dev This contract is only meant to be used via delegatecalls from another contract.
 * @dev Using this contract directly for swaps might result in reverts.
 */
contract Swapper is IScWETHSwapper {
    using SafeTransferLib for ERC20;
    using Address for address;

    ICurvePool public constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);

    WETH public constant weth = WETH(payable(C.WETH));
    ILido public constant stEth = ILido(C.STETH);
    IwstETH public constant wstEth = IwstETH(C.WSTETH);

    /**
     * @notice Swap tokens on Uniswap V3 using exact input multi route
     * @param _tokenIn Address of the token to swap
     * @param _amountIn Amount of the token to swap
     * @param _amountOutMin Minimum amount of the token to receive
     * @param _path abi.encodePacked(_tokenIn, fees, ...middleTokens, ...fees, _tokenOut)
     * @return amountOut Amount of the output token received
     */
    function uniswapSwapExactInputMultihop(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path
    ) external returns (uint256 amountOut) {
        amountOut = SwapperLib._uniswapSwapExactInputMultihop(_tokenIn, _amountIn, _amountOutMin, _path);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact input single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     * @param _poolFee Pool fee of the Uniswap V3 pool.
     * @return amountOut Amount of the output token received.
     */
    function uniswapSwapExactInput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint24 _poolFee
    ) external returns (uint256 amountOut) {
        amountOut =
            SwapperLib._uniswapSwapExactInput(address(_tokenIn), address(_tokenOut), _amountIn, _amountOutMin, _poolFee);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output multi route
     * @param _tokenIn Address of the token to swap
     * @param _amountOut Amount of the token to receive
     * @param _amountInMaximum Maximum amount of the token to swap
     * @param _path abi.encodePacked(_tokenOut, fees, ...middleTokens, ...fees, _tokenIn)
     * @return amountIn Amount of the input token used for the swap
     */
    function uniswapSwapExactOutputMultihop(
        address _tokenIn,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        bytes memory _path
    ) public returns (uint256 amountIn) {
        amountIn = SwapperLib._uniswapSwapExactOutputMultihop(_tokenIn, _amountOut, _amountInMaximum, _path);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountOut Amount of the token to receive.
     * @param _amountInMaximum Maximum amount of the token to swap.
     * @param _poolFee Pool fee of the Uniswap V3 pool.
     * @return amountIn Amount of the input token used for the swap
     */
    function uniswapSwapExactOutput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint24 _poolFee
    ) public returns (uint256 amountIn) {
        amountIn = SwapperLib._uniswapSwapExactOutput(
            address(_tokenIn), address(_tokenOut), _amountOut, _amountInMaximum, _poolFee
        );
    }

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
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external returns (uint256) {
        uint256 tokenOutInitialBalance = _tokenOut.balanceOf(address(this));

        _tokenIn.safeApprove(C.ZERO_EX_ROUTER, _amountIn);

        C.ZERO_EX_ROUTER.functionCall(_swapData);

        uint256 amountReceived = _tokenOut.balanceOf(address(this)) - tokenOutInitialBalance;

        if (amountReceived < _amountOutMin) revert AmountReceivedBelowMin();

        _tokenIn.approve(C.ZERO_EX_ROUTER, 0);

        return amountReceived;
    }

    /**
     * Swap WETH to wstETH using Lido or Curve for ETH to stETH conversion, whichever is cheaper.
     * @param _wethAmount Amount of WETH to swap.
     * @return Amount of wstETH received.
     */
    function lidoSwapWethToWstEth(uint256 _wethAmount) external returns (uint256) {
        // weth to eth
        weth.withdraw(_wethAmount);

        // eth to stEth
        // if curve exchange rate is better than lido's 1:1, use curve
        if (curvePool.get_dy(0, 1, _wethAmount) > _wethAmount) {
            curvePool.exchange{value: _wethAmount}(0, 1, _wethAmount, _wethAmount);
        } else {
            stEth.submit{value: _wethAmount}(address(0x00));
        }

        // stEth to wstEth
        uint256 stEthBalance = stEth.balanceOf(address(this));
        ERC20(address(stEth)).safeApprove(address(wstEth), stEthBalance);

        return wstEth.wrap(stEthBalance);
    }

    /**
     * Swap stETH to WETH on Curve.
     * @param _stEthAmount Amount of stETH to swap.
     * @param _wethAmountOutMin Minimum amount of WETH to receive.
     * @return wethReceived Amount of WETH received.
     */
    function curveSwapStEthToWeth(uint256 _stEthAmount, uint256 _wethAmountOutMin)
        external
        returns (uint256 wethReceived)
    {
        // stEth to eth
        ERC20(address(stEth)).safeApprove(address(curvePool), _stEthAmount);

        wethReceived = curvePool.exchange(1, 0, _stEthAmount, _wethAmountOutMin);

        // eth to weth
        weth.deposit{value: address(this).balance}();
    }
}
