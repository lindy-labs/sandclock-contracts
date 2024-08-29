// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

interface ISwapper {
    function zeroExSwap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external returns (uint256);
}

interface IScWETHSwapper is ISwapper {
    function curveSwapStEthToWeth(uint256 _stEthAmount, uint256 _wethAmountOutMin)
        external
        returns (uint256 wethReceived);

    function lidoSwapWethToWstEth(uint256 _wethAmount) external returns (uint256 wstEthReceived);
}

interface ISinglePairSwapper is ISwapper {
    function asset() external view returns (address);
    function targetToken() external view returns (address);

    function swapTargetTokenForAsset(uint256 _targetAmount, uint256 _assetAmountOutMin)
        external
        returns (uint256 amountReceived);

    function swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) external returns (uint256 amountSpent);
}
