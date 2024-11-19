// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {scUSDT} from "src/steth/scUSDT.sol";
import {UsdtWethPriceConverter} from "src/steth/priceConverter/UsdtWethPriceConverter.sol";
import {AaveV3ScUsdtAdapter} from "src/steth/scUsdt-adapters/AaveV3ScUsdtAdapter.sol";
import {UsdtWethSwapper} from "src/steth/swapper/UsdtWethSwapper.sol";

contract DeployScUsdt is MainnetDeployBase {
    function run() external returns (scUSDT scUsdt) {
        vm.startBroadcast(deployerAddress);

        /// step1 - deploy adapter, swapper, and price converter
        address aaveV3Adapter =
            deployWithCreate3(type(AaveV3ScUsdtAdapter).name, abi.encodePacked(type(AaveV3ScUsdtAdapter).creationCode));
        address swapper =
            deployWithCreate3(type(UsdtWethSwapper).name, abi.encodePacked(type(UsdtWethSwapper).creationCode));
        address priceConverter = deployWithCreate3(
            type(UsdtWethPriceConverter).name, abi.encodePacked(type(UsdtWethPriceConverter).creationCode)
        );

        // step2 - deploy scUSDT & add adapter
        scUsdt = scUSDT(
            deployWithCreate3(
                type(scUSDT).name,
                abi.encodePacked(
                    type(scUSDT).creationCode,
                    abi.encode(deployerAddress, keeper, MainnetAddresses.SCWETHV2, priceConverter, swapper)
                )
            )
        );

        scUsdt.addAdapter(AaveV3ScUsdtAdapter(aaveV3Adapter));

        // step3 - deposit initial funds & transfer admin role to multisig
        require(deployerAddress.balance >= 0.01 ether, "insufficient balance");
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        uint256 initialDeposit =
            SwapperLib._uniswapSwapExactInput(address(weth), C.USDT, deployerAddress, 0.01 ether, 0, 500);
        // deposit 0.01 ether worth of USDT
        _deposit(scUsdt, initialDeposit);

        _transferAdminRoleToMultisig(scUsdt);

        vm.stopBroadcast();
    }
}
