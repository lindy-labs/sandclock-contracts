// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {CREATE3Script} from "./CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {DeploymentConstants as DC} from "../../src/lib/DeploymentConstants.sol";
import {ICurvePool} from "../../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../../src/interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../../src/interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";
import {scWETH} from "../../src/steth/scWETH.sol";
import {scUSDC} from "../../src/steth/scUSDC.sol";

import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";

/**
 * Base Deployment file that handles Forked & Mainnet deployment.
 * Forked node deployments are equivalent to mainnet deployments.
 */
abstract contract DeployScWethV2AndScUsdcV2 is MainnetDeployBase {
    scWETH scWeth;
    scUSDC scUsdc;

    function _deploy() internal {
        vm.startBroadcast(deployerAddress);

        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: deployerAddress,
            keeper: keeper,
            targetLtv: 0.85e18,
            slippageTolerance: 0.99e18,
            aavePool: IPool(C.AAVE_V3_POOL),
            aaveAwstEth: IAToken(C.AAVE_V3_AWSTETH_TOKEN),
            aaveVarDWeth: ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN),
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: weth,
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        scWeth = new scWETH(scWethParams);
        console2.log("\nscWETH: ", address(scWeth));

        scUSDC.ConstructorParams memory scUsdcParams = scUSDC.ConstructorParams({
            admin: deployerAddress,
            keeper: keeper,
            scWETH: scWeth,
            usdc: usdc,
            weth: WETH(payable(C.WETH)),
            aavePool: IPool(C.AAVE_V3_POOL),
            aavePoolDataProvider: IPoolDataProvider(C.AAVE_V3_POOL_DATA_PROVIDER),
            aaveAUsdc: IAToken(C.AAVE_V3_AUSDC_TOKEN),
            aaveVarDWeth: ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN),
            uniswapSwapRouter: ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER),
            chainlinkUsdcToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        scUsdc = new scUSDC(scUsdcParams);
        console2.log("scUSDC: ", address(scUsdc));

        vm.stopBroadcast();
    }
}
