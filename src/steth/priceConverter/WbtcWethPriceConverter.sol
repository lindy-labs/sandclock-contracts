// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./IPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

contract WbtcWethPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    address public constant asset = C.WBTC;
    address public constant targetToken = C.WETH;

    AggregatorV3Interface public constant WBTC_ETH_PRICE_FEED = AggregatorV3Interface(C.CHAINLINK_WBTC_ETH_PRICE_FEED);

    function targetTokenToAsset(uint256 _wethAmount) external view override returns (uint256) {
        return _wethAmount.divWadDown(_wbtcPriceInEth() * C.WETH_WBTC_DECIMALS_DIFF);
    }

    function assetToTargetToken(uint256 _wbtcAmount) external view override returns (uint256) {
        return (_wbtcAmount * C.WETH_WBTC_DECIMALS_DIFF).mulWadDown(_wbtcPriceInEth());
    }

    function _wbtcPriceInEth() internal view returns (uint256) {
        (, int256 wbtcPriceInEth,,,) = WBTC_ETH_PRICE_FEED.latestRoundData();

        return uint256(wbtcPriceInEth);
    }
}
