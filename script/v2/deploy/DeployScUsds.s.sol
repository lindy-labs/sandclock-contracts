// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {scUSDS} from "src/steth/scUSDS.sol";

contract DeployScUsds is MainnetDeployBase {
    function run() external returns (scUSDS scUsds) {
        vm.startBroadcast(deployerAddress);

        // step 1 - deploy scUSDS wtih scSDAI target
        scUsds = scUSDS(
            deployWithCreate3(
                type(scUSDS).name, abi.encodePacked(type(scUSDS).creationCode, abi.encode(MainnetAddresses.SCSDAI))
            )
        );

        // step 2 - deposit initial funds
        require(deployerAddress.balance >= 0.01 ether, "insufficient balance");
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        bytes memory swapPath = abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI, uint24(3000), C.USDS);
        uint256 initialDeposit =
            SwapperLib._uniswapSwapExactInputMultihop(C.WETH, 0.01 ether, 0, swapPath, deployerAddress);
        // deposit 0.01 ether worth of USDS
        _deposit(scUsds, initialDeposit);

        vm.stopBroadcast();
    }
}
