// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {CREATE3Script} from "./CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {ICurvePool} from "../../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../../src/interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../../src/interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";
import {scWETH} from "../../src/steth/scWETH.sol";
import {scUSDC} from "../../src/steth/scUSDC.sol";

import {MockWETH} from "../../test/mocks/MockWETH.sol";
import {MockUSDC} from "../../test/mocks/MockUSDC.sol";
import {MockAavePool} from "../../test/mocks/aave-v3/MockAavePool.sol";
import {MockAavePoolDataProvider} from "../../test/mocks/aave-v3/MockAavePoolDataProvider.sol";
import {MockAUsdc} from "../../test/mocks/aave-v3/MockAUsdc.sol";
import {MockVarDebtWETH} from "../../test/mocks/aave-v3/MockVarDebtWETH.sol";
import {MockAwstETH} from "../../test/mocks/aave-v3/MockAwstETH.sol";

import {MockStETH} from "../../test/mocks/lido/MockStETH.sol";
import {MockWstETH} from "../../test/mocks/lido/MockWstETH.sol";
import {MockCurvePool} from "../../test/mocks/curve/MockCurvePool.sol";
import {MockChainlinkPriceFeed} from "../../test/mocks/chainlink/MockChainlinkPriceFeed.sol";
import {MockBalancerVault} from "../../test/mocks/balancer/MockBalancerVault.sol";
import {MockSwapRouter} from "../../test/mocks/uniswap/MockSwapRouter.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";

abstract contract DeployLeveragedEth is MainnetDeployBase {
    WETH _weth = WETH(payable(C.WETH));
    ERC20 _usdc = ERC20(C.USDC);
    MockAavePool _aavePool = MockAavePool(C.AAVE_V3_POOL);
    ICurvePool _curveEthStEthPool = ICurvePool(C.CURVE_ETH_STETH_POOL);
    ISwapRouter _uniswapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    scWETH _scWETH;
    scUSDC _scUSDC;

    uint256 _deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address _deployerAddress = vm.addr(_deployerPrivateKey);

    address _keeper = vm.envAddress("KEEPER");
    address _alice = C.ALICE;
    address _bob = C.BOB;

    function _deploy() internal {
        vm.startBroadcast(_deployerPrivateKey);

        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: _deployerAddress,
            keeper: _keeper,
            targetLtv: 0.7e18,
            slippageTolerance: 0.99e18,
            aavePool: _aavePool,
            aaveAwstEth: IAToken(C.AAVE_V3_AWSTETH_TOKEN),
            aaveVarDWeth: ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN),
            curveEthStEthPool: _curveEthStEthPool,
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: _weth,
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        _scWETH = new scWETH(scWethParams);
        console2.log("\nscWETH: ", address(_scWETH));

        scUSDC.ConstructorParams memory scUsdcParams = scUSDC.ConstructorParams({
            admin: _deployerAddress,
            keeper: _keeper,
            scWETH: _scWETH,
            usdc: _usdc,
            weth: WETH(payable(C.WETH)),
            aavePool: _aavePool,
            aavePoolDataProvider: IPoolDataProvider(C.AAVE_V3_POOL_DATA_PROVIDER),
            aaveAUsdc: IAToken(C.AAVE_V3_AUSDC_TOKEN),
            aaveVarDWeth: ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN),
            uniswapSwapRouter: _uniswapRouter,
            chainlinkUsdcToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        _scUSDC = new scUSDC(scUsdcParams);
        console2.log("scUSDC: ", address(_scUSDC));

        vm.stopBroadcast();
    }
}
