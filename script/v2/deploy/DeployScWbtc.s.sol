// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {scWBTC} from "src/steth/scWBTC.sol";
import {AaveV3ScWbtcAdapter} from "src/steth/scWbtc-adapters/AaveV3ScWbtcAdapter.sol";
import {WbtcWethSwapper} from "src/steth/swapper/WbtcWethSwapper.sol";
import {WbtcWethPriceConverter} from "src/steth/priceConverter/WbtcWethPriceConverter.sol";

contract DeployScWbtc is MainnetDeployBase {
    function run() external returns (scWBTC scWbtc) {
        vm.startBroadcast(deployerAddress);

        /// step1 - deploy adapter, swapper, and price converter
        address aaveV3Adapter =
            deployWithCreate3(type(AaveV3ScWbtcAdapter).name, abi.encodePacked(type(AaveV3ScWbtcAdapter).creationCode));
        address swapper =
            deployWithCreate3(type(WbtcWethSwapper).name, abi.encodePacked(type(WbtcWethSwapper).creationCode));
        address priceConverter = deployWithCreate3(
            type(WbtcWethPriceConverter).name, abi.encodePacked(type(WbtcWethPriceConverter).creationCode)
        );

        console2.log("keeper", keeper);

        // step 2 - deploy scWBTC wtih scWETHv2 target & add adapter
        scWbtc = scWBTC(
            deployWithCreate3(
                type(scWBTC).name,
                abi.encodePacked(
                    type(scWBTC).creationCode,
                    abi.encode(deployerAddress, keeper, MainnetAddresses.SCWETHV2, priceConverter, swapper)
                )
            )
        );

        scWbtc.addAdapter(AaveV3ScWbtcAdapter(aaveV3Adapter));

        // step 3 - deposit initial funds
        require(deployerAddress.balance >= 0.01 ether, "insufficient balance");
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH

        uint256 initialDeposit =
            SwapperLib._uniswapSwapExactInput(address(weth), C.WBTC, deployerAddress, 0.01 ether, 0, 500);
        // deposit 0.01 ether worth of WBTC
        _deposit(scWbtc, initialDeposit);

        // step4 - transfer admin role to multisig
        _transferAdminRoleToMultisig(scWbtc);

        vm.stopBroadcast();
    }
}
