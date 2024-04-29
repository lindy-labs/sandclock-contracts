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
    IRouter public constant router = IRouter(C.BASE_AERODROME_ROUTER);

    // Uniswap V3 router
    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);
    ICurvePool public constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);
    ILido public constant stEth = ILido(C.STETH);

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
    ) external returns (uint256) {}

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
    ) external returns (uint256) {}

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
    ) external returns (uint256) {}

    /**
     * Swap WETH to wstETH using Lido or Curve for ETH to stETH conversion, whichever is cheaper.
     * @param _wethAmount Amount of WETH to swap.
     * @return Amount of wstETH received.
     */
    function lidoSwapWethToWstEth(uint256 _wethAmount) external returns (uint256) {}

    /**
     * Swap stETH to WETH on Curve.
     * @param _stEthAmount Amount of stETH to swap.
     * @param _wethAmountOutMin Minimum amount of WETH to receive.
     * @return wethReceived Amount of WETH received.
     */
    function curveSwapStEthToWeth(uint256 _stEthAmount, uint256 _wethAmountOutMin)
        external
        returns (uint256 wethReceived)
    {}
}
