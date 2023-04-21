// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {LendingMarketManager} from "../../src/phase-2/LendingMarketManager.sol";
import {Constants as C} from "../../src/lib/Constants.sol";
import {LendingMarketManager} from "../../src/phase-2/LendingMarketManager.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../../src/interfaces/balancer/IVault.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../../src/sc4626.sol";

contract MockLendingMarketManager is
    LendingMarketManager(
        ILido(C.STETH),
        IwstETH(C.WSTETH),
        WETH(payable(C.WETH)),
        AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
        ICurvePool(C.CURVE_ETH_STETH_POOL),
        IVault(C.BALANCER_VAULT)
    )
{}
