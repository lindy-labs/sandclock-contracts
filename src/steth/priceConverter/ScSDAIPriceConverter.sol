// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "lib/forge-std/src/interfaces/IERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./IPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

contract scSDAIPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    IERC4626 public constant sDai = IERC4626(C.SDAI);

    // Chainlink price feed (DAI -> ETH)
    AggregatorV3Interface public constant DAI_ETH_PRICE_FEED = AggregatorV3Interface(C.CHAINLINK_DAI_ETH_PRICE_FEED);

    function tokenToBaseAsset(uint256 _ethAmount) external view override returns (uint256) {
        return sDai.convertToShares(_ethToDai(_ethAmount));
    }

    function baseAssetToToken(uint256 _sDaiAmount) external view override returns (uint256) {
        return _daiToEth(sDai.convertToAssets(_sDaiAmount));
    }

    function _ethToDai(uint256 _ethAmount) internal view returns (uint256) {
        return _ethAmount.divWadDown(_daiPriceInEth());
    }

    function _daiToEth(uint256 _daiAmount) internal view returns (uint256) {
        return _daiAmount.mulWadDown(_daiPriceInEth());
    }

    function _daiPriceInEth() internal view returns (uint256) {
        (, int256 daiPriceInEth,,,) = DAI_ETH_PRICE_FEED.latestRoundData();

        return uint256(daiPriceInEth);
    }
}
