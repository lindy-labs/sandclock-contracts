// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {AmountReceivedBelowMin} from "../errors/scErrors.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
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

    // Uniswap V3 router
    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

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
     */
    function uniswapSwapExactInputMultihop(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path
    ) public returns (uint256) {
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
     * @notice Swap tokens on Uniswap V3 using exact output multi route
     * @param _tokenIn Address of the token to swap
     * @param _amountOut Amount of the token to receive
     * @param _amountInMaximum Maximum amount of the token to swap
     * @param _path abi.encodePacked(_tokenOut, fees, ...middleTokens, ...fees, _tokenIn)
     */
    function uniswapSwapExactOutputMultihop(
        address _tokenIn,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        bytes memory _path
    ) public returns (uint256) {
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

    function uniswapSwapExactOutput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint24 _poolFee
    ) public returns (uint256) {
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

    /**
     * Swap exact amount  of Weth to sDai
     * @param _wethAmount amount of weth to swap
     * @param _sDaiAmountOutMin minimum amount of sDai to receive after the swap
     * @return sDaiReceived amount of sDai received.
     */
    function swapWethToSdai(uint256 _wethAmount, uint256 _sDaiAmountOutMin) external returns (uint256 sDaiReceived) {
        // weth => usdc => dai
        uint256 daiAmount = uniswapSwapExactInputMultihop(
            C.WETH, _wethAmount, 1, abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
        );

        sDaiReceived = _swapDaiToSdai(daiAmount);

        if (sDaiReceived < _sDaiAmountOutMin) revert AmountReceivedBelowMin();
    }

    /**
     * Swap sdai to exact amount of weth
     * @param _sDaiAmountOutMaximum maximum amount of sDai to swap for weth
     * @param _wethAmountOut amount of weth to receive
     */
    function swapSdaiForExactWeth(uint256 _sDaiAmountOutMaximum, uint256 _wethAmountOut) external {
        // sdai => dai
        uint256 daiAmount = _swapSdaiToDai(_sDaiAmountOutMaximum);

        // dai => usdc => weth
        uniswapSwapExactOutputMultihop(
            C.DAI, _wethAmountOut, daiAmount, abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
        );

        // remaining dai to sdai
        _swapDaiToSdai(_daiBalance());
    }

    ////////////////////////////////// INTERNAL FUNCTIONS //////////////////////////////////////////////////////

    function _swapSdaiToDai(uint256 _sDaiAmount) internal returns (uint256) {
        return ERC4626(C.SDAI).redeem(_sDaiAmount, address(this), address(this));
    }

    function _swapDaiToSdai(uint256 _daiAmount) internal returns (uint256) {
        return ERC4626(C.SDAI).deposit(_daiAmount, address(this));
    }

    function _daiBalance() internal view returns (uint256) {
        return ERC20(C.DAI).balanceOf(address(this));
    }
}
