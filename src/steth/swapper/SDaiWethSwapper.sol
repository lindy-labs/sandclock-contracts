// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "../swapper/ISwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";

contract SDaiWethSwapper is ISinglePairSwapper, UniversalSwapper {
    address public constant asset = address(C.SDAI);
    address public constant targetToken = address(C.WETH);
    // intermmediate token for swap
    ERC20 public constant dai = ERC20(C.DAI);

    bytes public constant swapPath = abi.encodePacked(targetToken, uint24(500), C.USDC, uint24(100), dai);

    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _sDaiAmountOutMin)
        external
        override
        returns (uint256 sDaiReceived)
    {
        uint256 daiAmountOutMin = ERC4626(asset).convertToAssets(_sDaiAmountOutMin);

        uint256 daiReceived =
            SwapperLib._uniswapSwapExactInputMultihop(targetToken, _wethAmount, daiAmountOutMin, swapPath);

        sDaiReceived = ERC4626(asset).deposit(daiReceived, address(this));
    }

    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 sDaiSpent) {
        // unwrap all sdai to dai
        uint256 sDaiBalance = ERC20(asset).balanceOf(address(this));

        uint256 daiBalance = ERC4626(asset).redeem(sDaiBalance, address(this), address(this));

        // swap dai for exact weth
        uint256 daiSpent =
            SwapperLib._uniswapSwapExactOutputMultihop(address(dai), _wethAmountOut, daiBalance, swapPath);

        // deposit remaining dai to sdai
        uint256 remainingSDai = ERC4626(asset).deposit(daiBalance - daiSpent, address(this));

        sDaiSpent = sDaiBalance - remainingSDai;
    }
}
