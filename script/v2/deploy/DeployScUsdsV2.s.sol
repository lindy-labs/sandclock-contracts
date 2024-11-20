// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {scUSDSv2} from "src/steth/scUSDSv2.sol";
import {AaveV3ScUsdsAdapter} from "src/steth/scUsds-adapters/AaveV3ScUsdsAdapter.sol";
import {UsdsWethSwapper} from "src/steth/swapper/UsdsWethSwapper.sol";
import {DaiWethPriceConverter} from "src/steth/priceConverter/DaiWethPriceConverter.sol";

contract DeployScUsdsV2 is MainnetDeployBase {
    function run() external returns (scUSDSv2 scUsds) {
        vm.startBroadcast(deployerAddress);

        /// step1 - deploy adapter, swapper, and price converter
        address aaveV3Adapter =
            deployWithCreate3(type(AaveV3ScUsdsAdapter).name, abi.encodePacked(type(AaveV3ScUsdsAdapter).creationCode));
        address swapper =
            deployWithCreate3(type(UsdsWethSwapper).name, abi.encodePacked(type(UsdsWethSwapper).creationCode));
        address priceConverter = deployWithCreate3(
            type(DaiWethPriceConverter).name, abi.encodePacked(type(DaiWethPriceConverter).creationCode)
        );

        console2.log("keeper", keeper);

        // step 2 - deploy scUSDSv2 wtih scWETHv2 target & add adapter
        scUsds = scUSDSv2(
            deployWithCreate3(
                type(scUSDSv2).name,
                abi.encodePacked(
                    type(scUSDSv2).creationCode,
                    abi.encode(deployerAddress, keeper, MainnetAddresses.SCWETHV2, priceConverter, swapper)
                )
            )
        );

        scUsds.addAdapter(AaveV3ScUsdsAdapter(aaveV3Adapter));

        // step 3 - deposit initial funds
        require(deployerAddress.balance >= 0.01 ether, "insufficient balance");
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        bytes memory swapPath = abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI, uint24(3000), C.USDS);
        uint256 initialDeposit =
            SwapperLib._uniswapSwapExactInputMultihop(C.WETH, 0.01 ether, 0, swapPath, deployerAddress);
        // deposit 0.01 ether worth of USDS
        _deposit(scUsds, initialDeposit);

        // step4 - transfer admin role to multisig
        _transferAdminRoleToMultisig(scUsds);

        vm.stopBroadcast();
    }
}
