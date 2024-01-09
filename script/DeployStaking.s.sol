// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {CREATE3Script} from "./base/CREATE3Script.sol";
import {RewardTracker} from "../src/staking/RewardTracker.sol";
import {MainnetAddresses as MA} from "./base/MainnetAddresses.sol";
import {Constants as C} from "../src/lib/Constants.sol";

contract DeployStaking is CREATE3Script {
    string public NAME = "Staked Quartz";
    string public SYMBOL = "sQuartz";
    uint64 public constant DURATION = 30 days;

    uint256 deployerPrivateKey;
    address distributor;
    address treasury;

    function _init() internal virtual {
        deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        distributor = vm.envAddress("DISTRIBUTOR");
        treasury = vm.envAddress("TREASURY");
    }

    function run() external returns (RewardTracker sQuartz) {
        _init();

        require(deployerPrivateKey != 0, "Deployer private key not set");
        require(distributor != address(0), "Distributor not set");
        require(treasury != address(0), "Treasury not set");

        vm.startBroadcast(deployerPrivateKey);

        bytes memory creationCode = abi.encodePacked(
            type(RewardTracker).creationCode,
            abi.encode(vm.addr(deployerPrivateKey), treasury, MA.QUARTZ, NAME, SYMBOL, C.WETH, DURATION)
        );

        sQuartz = RewardTracker(create3.deploy(getCreate3ContractSalt("RewardTracker"), creationCode));

        sQuartz.grantRole(sQuartz.DISTRIBUTOR(), distributor);

        // add scWETHv2
        sQuartz.addVault(MA.SCWETHV2);

        vm.stopBroadcast();
    }
}
