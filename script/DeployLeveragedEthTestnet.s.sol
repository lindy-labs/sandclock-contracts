// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
// import "forge-std/Test.sol";
import {CREATE3Script} from "./base/CREATE3Script.sol";
import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";

import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockAavePool} from "../test/mocks/aave-v3/MockAavePool.sol";
import {MockAavePoolDataProvider} from "../test/mocks/aave-v3/MockAavePoolDataProvider.sol";
import {MockAUsdc} from "../test/mocks/aave-v3/MockAUsdc.sol";
import {MockVarDebtWETH} from "../test/mocks/aave-v3/MockVarDebtWETH.sol";
import {MockAwstETH} from "../test/mocks/aave-v3/MockAwstETH.sol";

import {MockStETH} from "../test/mocks/lido/MockStETH.sol";
import {MockWstETH} from "../test/mocks/lido/MockWstETH.sol";
import {MockCurvePool} from "../test/mocks/curve/MockCurvePool.sol";
import {MockChainlinkPriceFeed} from "../test/mocks/chainlink/MockChainlinkPriceFeed.sol";
import {MockBalancerVault} from "../test/mocks/balancer/MockBalancerVault.sol";
import {MockSwapRouter} from "../test/mocks/uniswap/MockSwapRouter.sol";

contract DeployScript is DeployLeveragedEth {
    function run() external {
        deployMocks();
        deploy();
    }
}
