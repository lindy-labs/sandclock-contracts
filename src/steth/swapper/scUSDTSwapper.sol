// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISwapRouter} from "../../interfaces/uniswap/ISwapRouter.sol";
import {ISinglePairSwapper} from "./../swapper/ISwapper.sol";

contract scUSDTSwapper is ISinglePairSwapper {
    using SafeTransferLib for ERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    address public constant override asset = address(C.USDT);
    address public constant override targetToken = address(C.WETH);

    function swapTargetTokenForAsset(uint256 _targetAmount, uint256 _assetAmountOutMin)
        external
        override
        returns (uint256)
    {
        ERC20(targetToken).safeApprove(address(swapRouter), _targetAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: targetToken,
            tokenOut: asset,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _targetAmount,
            amountOutMinimum: _assetAmountOutMin,
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }

    function swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) external override returns (uint256) {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: asset,
            tokenOut: targetToken,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _targetTokenAmountOut,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });

        ERC20(asset).safeApprove(address(swapRouter), type(uint256).max);

        uint256 amountIn = swapRouter.exactOutputSingle(params);

        ERC20(asset).safeApprove(address(swapRouter), 0);

        return amountIn;
    }
}
