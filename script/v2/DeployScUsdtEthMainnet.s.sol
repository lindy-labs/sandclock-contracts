// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scUSDT} from "../../src/steth/scUSDT.sol";
import {Swapper} from "../../src/steth/swapper/Swapper.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {UsdtWethPriceConverter} from "../../src/steth/priceConverter/UsdtWethPriceConverter.sol";
import {AaveV3ScUsdtAdapter} from "../../src/steth/scUsdt-adapters/AaveV3ScUsdtAdapter.sol";
import {UsdtWethSwapper} from "../../src/steth/swapper/UsdtWethSwapper.sol";
import {Constants as C} from "../../src/lib/Constants.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";

contract DeployScriptScUsdtEthMainnet is MainnetDeployBase {
    function run() external {
        vm.startBroadcast(deployerAddress);

        console2.log("deployerAddress", deployerAddress);

        scWETHv2 scWethV2 = scWETHv2(payable(MainnetAddresses.SCWETHV2));
        UsdtWethSwapper swapper = new UsdtWethSwapper();
        UsdtWethPriceConverter priceConverter = new UsdtWethPriceConverter();

        // deploy vault
        scUSDT scUsdt = new scUSDT(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        console2.log("scUSDT:", address(scUsdt));

        // deploy & add adapters
        AaveV3ScUsdtAdapter aaveV3Adapter = new AaveV3ScUsdtAdapter();
        scUsdt.addAdapter(aaveV3Adapter);
        console2.log("scUSDT AaveV3Adapter:", address(aaveV3Adapter));
        console2.log("swapper:", address(swapper));
        console2.log("priceConverter:", address(priceConverter));
        console2.log("scUSDT AaveV3Adapter:", address(aaveV3Adapter));

        vm.stopBroadcast();
    }

    function _swapWethForUsdt(uint256 _amount) internal returns (uint256 amountOut) {
        weth.deposit{value: _amount}();

        weth.approve(C.UNISWAP_V3_SWAP_ROUTER, _amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: C.USDT,
            fee: 500, // 0.05%
            recipient: deployerAddress,
            deadline: block.timestamp + 1000,
            amountIn: _amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amountOut = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER).exactInputSingle(params);
    }
}
