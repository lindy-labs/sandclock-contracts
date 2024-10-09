// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../lib/Constants.sol";
import {ISinglePairSwapper} from "./swapper/ISinglePairSwapper.sol";
import {ISinglePairPriceConverter} from "./priceConverter/ISinglePairPriceConverter.sol";
import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";

/**
 * @title Sandclock USDC Vault version 2
 * @notice Sandclock USDC Vault implementation.
 * @dev Inherits from scCrossAssetYieldVault to manage and generate USDC yield.
 */
contract scUSDCv2 is scCrossAssetYieldVault {
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
            ERC20(C.USDC),
            _targetVault,
            _priceConverter,
            _swapper,
            "Sandclock Yield USDC",
            "scUSDC"
        )
    {}
}
