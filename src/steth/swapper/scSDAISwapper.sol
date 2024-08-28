// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "../swapper/ISwapper.sol";
import {ISwapRouter} from "../../interfaces/uniswap/ISwapRouter.sol";

contract scSDAISwapper is ISinglePairSwapper {
    using SafeTransferLib for ERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    address public constant asset = address(C.SDAI);
    address public constant targetToken = address(C.WETH);
    // intermmediate token to swap to
    ERC4626 public constant dai = ERC4626(C.DAI);

    bytes public constant swapPath = abi.encodePacked(targetToken, uint24(500), C.USDC, uint24(100), asset);

    function swapTargetTokenForAsset(uint256 _targetAmount, uint256 _assetAmountOutMin)
        external
        override
        returns (uint256 sDaiReceived)
    {
        ERC20(targetToken).safeApprove(address(swapRouter), _targetAmount);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: swapPath,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _targetAmount,
            amountOutMinimum: _assetAmountOutMin
        });

        uint256 daiReceived = swapRouter.exactInput(params);

        sDaiReceived = ERC4626(asset).deposit(daiReceived, address(this));
    }

    function swapAssetForExactTargetToken(uint256 _targetTokenAmountOut)
        external
        override
        returns (uint256 sDaiSpent)
    {
        // unwrap all sdai to dai
        uint256 sDaiBalance = ERC20(asset).balanceOf(address(this));
        uint256 daiBalance = ERC4626(asset).redeem(sDaiBalance, address(this), address(this));

        ERC20(dai).safeApprove(address(swapRouter), daiBalance);

        ISwapRouter.ExactOutputParams memory params = ISwapRouter.ExactOutputParams({
            path: swapPath,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _targetTokenAmountOut,
            amountInMaximum: daiBalance
        });

        uint256 daiSpent = swapRouter.exactOutput(params);

        ERC20(dai).approve(address(swapRouter), 0);

        uint256 remainingSDai = ERC4626(asset).deposit(daiBalance - daiSpent, address(this));

        sDaiSpent = sDaiBalance - remainingSDai;
    }
}
