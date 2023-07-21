// SPDX-License-Identifier: MIT
pragma solidity >0.8.10;

import {IPriceFeed} from "../../../src/interfaces/liquity/IPriceFeed.sol";

contract MockPriceFeed is IPriceFeed {
    string public constant NAME = "PriceFeed";

    uint256 public price;

    function lastGoodPrice() external view override returns (uint256) {
        return price;
    }

    function fetchPrice() external view override returns (uint256) {
        return price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }
}
