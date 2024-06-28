// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";

import {scSkeleton} from "./scSkeleton.sol";
import {Constants as C} from "../lib/Constants.sol";
import {BaseV2Vault} from "./BaseV2Vault.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IAdapter} from "./IAdapter.sol";
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {MainnetAddresses as M} from "../../script/base/MainnetAddresses.sol";

contract scUSDT is scSkeleton {
    constructor(address _admin, address _keeper, PriceConverter _priceConverter, Swapper _swapper)
        scSkeleton(
            "Sandclock USDT Vault",
            "scUSDT",
            ERC20(C.USDT),
            ERC4626(M.SCWETHV2),
            _admin,
            _keeper,
            _priceConverter,
            _swapper
        )
    {}
}

contract scDAIPriceConverter is PriceConverter {
    constructor() PriceConverter(address(0x00)) {}

    function targetTokenToAsset(uint256 _amount) public view override returns (uint256) {}

    function assetToTargetToken(uint256 _amount) public view override returns (uint256) {}
}

contract scDAISwapper is Swapper {}
