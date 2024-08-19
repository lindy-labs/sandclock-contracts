// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./IPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

contract scUSDCPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    AggregatorV3Interface public constant usdcToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED);

    function tokenToBaseAsset(uint256 _wethAmount) external view override returns (uint256 usdcAmount) {
        usdcAmount = _wethAmount.divWadDown(_usdtPriceInEth() * C.WETH_USDC_DECIMALS_DIFF);
    }

    function baseAssetToToken(uint256 _usdcAmount) external view override returns (uint256 wethAmount) {
        wethAmount = (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(_usdtPriceInEth());
    }

    function _usdtPriceInEth() internal view returns (uint256) {
        (, int256 usdtPriceInEth,,,) = usdcToEthPriceFeed.latestRoundData();

        return uint256(usdtPriceInEth);
    }
}
