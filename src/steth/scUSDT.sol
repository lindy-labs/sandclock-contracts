// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";
import {Constants as C} from "../lib/Constants.sol";
import {ISinglePairPriceConverter} from "./priceConverter/IPriceConverter.sol";
import {ISinglePairSwapper} from "./swapper/ISwapper.sol";

contract scUSDT is scCrossAssetYieldVault {
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
            ERC20(C.USDT),
            _targetVault,
            _priceConverter,
            _swapper,
            "Sandclock USDT Vault",
            "scUSDT"
        )
    {}
}
