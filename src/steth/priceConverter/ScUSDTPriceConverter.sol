// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./IPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

contract scUSDTPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    AggregatorV3Interface public constant USDT_ETH_PRICE_FEED = AggregatorV3Interface(C.CHAINLINK_USDT_ETH_PRICE_FEED);

    function tokenToBaseAsset(uint256 _wethAmount) external view override returns (uint256 usdtAmount) {
        usdtAmount = _wethAmount.divWadDown(_usdtPriceInEth() * C.WETH_USDT_DECIMALS_DIFF);
    }

    function baseAssetToToken(uint256 _usdtAmount) external view override returns (uint256 wethAmount) {
        wethAmount = (_usdtAmount * C.WETH_USDT_DECIMALS_DIFF).mulWadDown(_usdtPriceInEth());
    }

    function _usdtPriceInEth() internal view returns (uint256) {
        (, int256 usdtPriceInEth,,,) = USDT_ETH_PRICE_FEED.latestRoundData();

        return uint256(usdtPriceInEth);
    }
}
