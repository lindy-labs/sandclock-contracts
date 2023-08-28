// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

library scWETHv2StrategyParams {
    // NOTE: If allocation percents need to be changed, use the reallocation script first, and only then change the values here
    // Do not change them directly here without calling reallocation script first,
    // else only subsequent invests will be done at the new allocation percents
    uint256 public constant MORPHO_ALLOCATION_PERCENT = 0.4e18;
    uint256 public constant COMPOUNDV3_ALLOCATION_PERCENT = 0.6e18;

    uint256 public constant MORPHO_TARGET_LTV = 0.8e18;
    uint256 public constant COMPOUNDV3_TARGET_LTV = 0.8e18;
}
