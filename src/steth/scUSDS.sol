// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../lib/Constants.sol";
import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";
import {ISinglePairPriceConverter} from "./priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "./swapper/ISinglePairSwapper.sol";
import {MainnetAddresses as MA} from "../../script/base/MainnetAddresses.sol";

/**
 * @title scUSDS
 * @notice Sandclock USDT Vault implementation.
 * @dev Inherits from scCrossAssetYieldVault to manage and generate sUSDS yield.
 */
contract scSUSDS is scCrossAssetYieldVault {
    using SafeTransferLib for ERC20;

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
            ERC20(C.SUSDS),
            _targetVault,
            _priceConverter,
            _swapper,
            "Sandclock SUSDS Vault",
            "scSUSDS"
        )
    {
        ERC20(C.USDS).safeApprove(address(asset), type(uint256).max);
    }
}
