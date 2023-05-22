// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {sc4626} from "../sc4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

abstract contract scUSDCBase is sc4626 {
    constructor(address _admin, address _keeper, ERC20 _asset, string memory _name, string memory _symbol)
        sc4626(_admin, _keeper, _asset, _name, _symbol)
    {}

    uint256 public floatPercentage = 0.01e18;

    event FloatPercentageUpdated(address indexed user, uint256 newFloatPercentage);

    function setFloatPercentage(uint256 newFloatPercentage) external {
        onlyAdmin();
        require(newFloatPercentage <= 1e18, "float percentage too high");
        floatPercentage = newFloatPercentage;
        emit FloatPercentageUpdated(msg.sender, newFloatPercentage);
    }
}
