// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {AmountReceivedBelowMin} from "../errors/scErrors.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {IRouter} from "../interfaces/aerodrome/IRouter.sol";
import {Constants as C} from "../lib/Constants.sol";

/**
 * @title Swapper
 * @notice Contract facilitating token swaps on Uniswap V3 and 0x.
 * @dev This contract is only meant to be used via delegatecalls from another contract.
 * @dev Using this contract directly for swaps might result in reverts.
 */
contract Swapper {
    using SafeTransferLib for ERC20;
    using Address for address;

    WETH public constant weth = WETH(payable(C.BASE_WETH));
    IwstETH public constant wstEth = IwstETH(C.BASE_WSTETH);

    // Uniswap V3 router
    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);
    ICurvePool public constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);
    ILido public constant stEth = ILido(C.STETH);

    IRouter public constant router = IRouter(C.BASE_AERODROME_ROUTER);

    function baseSwapWethToWstEth(uint256 _wethAmount, uint256 _wstEthAmountOutMin, address _vault)
        external
        returns (uint256)
    {
        weth.approve(address(router), _wethAmount);

        IRouter.Route memory route =
            IRouter.Route({from: C.BASE_WETH, to: C.BASE_WSTETH, stable: false, factory: C.BASE_AERODROME_FACTORY});

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = route;

        uint256[] memory amounts =
            router.swapExactTokensForTokens(_wethAmount, _wstEthAmountOutMin, routes, _vault, block.timestamp);

        return amounts[1];
    }

    function baseSwapWstEthToWeth(uint256 _wstEthAmount, uint256 _wethAmountOutMin, address _vault)
        external
        returns (uint256)
    {
        wstEth.approve(address(router), _wstEthAmount);

        IRouter.Route memory route =
            IRouter.Route({from: C.BASE_WSTETH, to: C.BASE_WETH, stable: false, factory: C.BASE_AERODROME_FACTORY});

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = route;

        uint256[] memory amounts =
            router.swapExactTokensForTokens(_wstEthAmount, _wethAmountOutMin, routes, _vault, block.timestamp);

        return amounts[1];
    }

    /**
     * @notice Swap tokens on 0x protocol.
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
     * @notice Swap tokens on Uniswap V3 using exact input single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     * @param _poolFee Pool fee of the Uniswap V3 pool.
     * @return Amount of the token received.
     */
    function uniswapSwapExactInput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint24 _poolFee
    ) external returns (uint256) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(_tokenIn),
            tokenOut: address(_tokenOut),
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
     * @notice Swap tokens on Uniswap V3 using exact output single function.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountOut Amount of the token to receive.
     * @param _amountInMaximum Maximum amount of the token to swap.
     * @param _poolFee Pool fee of the Uniswap V3 pool.
     * @return Amount of the token swapped.
     */
    function uniswapSwapExactOutput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint24 _poolFee
    ) external returns (uint256) {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(_tokenIn),
            tokenOut: address(_tokenOut),
            fee: _poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _amountOut,
            amountInMaximum: _amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        _tokenIn.safeApprove(address(swapRouter), _amountInMaximum);

        uint256 amountIn = swapRouter.exactOutputSingle(params);

        _tokenIn.safeApprove(address(swapRouter), 0);

        return amountIn;
    }

    /**
     * Swap WETH to wstETH using Lido or Curve for ETH to stETH conversion, whichever is cheaper.
     * @param _wethAmount Amount of WETH to swap.
     * @return Amount of wstETH received.
     */
    function lidoSwapWethToWstEth(uint256 _wethAmount) external returns (uint256) {
        // // weth to eth
        // weth.withdraw(_wethAmount);

        // // eth to stEth
        // // if curve exchange rate is better than lido's 1:1, use curve
        // if (curvePool.get_dy(0, 1, _wethAmount) > _wethAmount) {
        //     curvePool.exchange{value: _wethAmount}(0, 1, _wethAmount, _wethAmount);
        // } else {
        //     stEth.submit{value: _wethAmount}(address(0x00));
        // }

        // // stEth to wstEth
        // uint256 stEthBalance = stEth.balanceOf(address(this));
        // ERC20(address(stEth)).safeApprove(address(wstEth), stEthBalance);

        // return wstEth.wrap(stEthBalance);
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
        // // stEth to eth
        // ERC20(address(stEth)).safeApprove(address(curvePool), _stEthAmount);

        // wethReceived = curvePool.exchange(1, 0, _stEthAmount, _wethAmountOutMin);

        // // eth to weth
        // weth.deposit{value: address(this).balance}();
    }
}
