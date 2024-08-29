// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "./../swapper/ISwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {ZeroXSwapper} from "./ZeroXSwapper.sol";

contract UsdtWethSwapper is ISinglePairSwapper, ZeroXSwapper {
    address public constant override asset = address(C.USDT);
    address public constant override targetToken = address(C.WETH);
    uint24 public constant POOL_FEE = 500;

    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdtAmountOutMin)
        external
        override
        returns (uint256 usdtReceived)
    {
        usdtReceived = SwapperLib._uniswapSwapExactInput(targetToken, asset, _wethAmount, _usdtAmountOutMin, POOL_FEE);
    }

    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 usdtSpent) {
        uint256 usdtBalance = ERC20(asset).balanceOf(address(this));

        usdtSpent = SwapperLib._uniswapSwapExactOutput(asset, targetToken, _wethAmountOut, usdtBalance, POOL_FEE);
    }
}
