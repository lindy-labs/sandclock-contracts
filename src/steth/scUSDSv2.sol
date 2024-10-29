// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";
import {Constants as C} from "../lib/Constants.sol";
import {ISinglePairPriceConverter} from "./priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "./swapper/ISinglePairSwapper.sol";

/**
 * @title scUSDSv2
 * @notice Sandclock USDS Vault implementation.
 * @dev Inherits from scCrossAssetYieldVault to manage and generate USDS yield.
 * @dev There is no USDS Chainlink Feed, but since USDS to DAI is always 1:1 so
 * maybe we can use the DAI Price Converter here.
 */
contract scUSDSv2 is scCrossAssetYieldVault {
    constructor(
        address _admin,
        address _keeper,
        ERC4626 _targetVault,
        ISinglePairPriceConverter _priceConverter,
        ISinglePairSwapper _swapper
    )
        scCrossAssetYieldVault(
            _admin,
            _keeper,
            ERC20(C.USDS),
            _targetVault,
            _priceConverter,
            _swapper,
            "Sandclock USDS Real Yield Vault",
            "scUSDSv2"
        )
    {}
}
