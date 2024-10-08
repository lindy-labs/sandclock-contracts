// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {ICREATE3Factory} from "create3-factory/ICREATE3Factory.sol";

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
        UsdtWethSwapper swapper = UsdtWethSwapper(_deploy("UsdtWethSwapper", ""));
        UsdtWethPriceConverter priceConverter = UsdtWethPriceConverter(_deploy("UsdtWethPriceConverter", ""));

        // deploy vault
        bytes memory args = abi.encode(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        scUSDT scUsdt = scUSDT(_deploy("scUSDT", args));

        console2.log("scUSDT:", address(scUsdt));

        // deploy adapters
        AaveV3ScUsdtAdapter aaveV3Adapter = AaveV3ScUsdtAdapter(_deploy("AaveV3ScUsdtAdapter", ""));

        // add adapter
        scUsdt.addAdapter(aaveV3Adapter);

        console2.log("AaveV3Adapter:", address(aaveV3Adapter));
        console2.log("swapper:", address(swapper));
        console2.log("priceConverter:", address(priceConverter));

        vm.stopBroadcast();
    }

    function _deploy(string memory contractName, bytes memory args) internal returns (address) {
        ICREATE3Factory factory = ICREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

        bytes memory byteCode;
        if (args.length == 0) {
            byteCode = abi.encodePacked(vm.getCode(contractName));
        } else {
            byteCode = abi.encodePacked(vm.getCode(contractName), args);
        }

        bytes32 salt = bytes32(bytes(contractName));

        return factory.deploy(salt, byteCode);
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
