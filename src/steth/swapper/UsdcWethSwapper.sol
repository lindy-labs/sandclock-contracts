// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISwapRouter} from "../../interfaces/uniswap/ISwapRouter.sol";
import {ISinglePairSwapper} from "./../swapper/ISwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";

contract UsdcWethSwapper is ISinglePairSwapper {
    using SafeTransferLib for ERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    address public constant override asset = address(C.USDC);
    address public constant override targetToken = address(C.WETH);
    uint24 public constant POOL_FEE = 500;

    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdcAmountOutMin)
        external
        override
        returns (uint256 usdcReceived)
    {
        usdcReceived = SwapperLib._uniswapSwapExactInput(targetToken, asset, _wethAmount, _usdcAmountOutMin, POOL_FEE);
    }

    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 usdcSpent) {
        uint256 usdcBalance = ERC20(asset).balanceOf(address(this));

        usdcSpent = SwapperLib._uniswapSwapExactOutput(asset, targetToken, _wethAmountOut, usdcBalance, POOL_FEE);
    }
}
