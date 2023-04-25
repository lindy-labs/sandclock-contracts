// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {RewardTracker} from "../src/staking/RewardTracker.sol";
import {BonusTracker} from "../src/staking/BonusTracker.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MintableERC20} from "../src/staking/utils/MintableERC20.sol";

contract DeployScript is CREATE3Script {
    bytes32 public constant DISTRIBUTOR = keccak256("DISTRIBUTOR");

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (BonusTracker sQuartz) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        MockERC20 quartz;
        MintableERC20 bnQuartz;
        RewardTracker sfQuartz;
        address WETH = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6; // weth on goerli

        vm.startBroadcast(deployerPrivateKey);

        quartz = new MockERC20("Mock Quartz", "QUARTZ", 18);
        bnQuartz = new MintableERC20("Mock Multiplier Points", "bnQuartz", 18);
        sfQuartz =
            new RewardTracker(address(quartz), "Staked + Fee Quartz", "sfQuartz", WETH, address(bnQuartz), 30 days);
        sQuartz = new BonusTracker(address(sfQuartz), "Staked Quartz", "sQuartz", address(bnQuartz));

        vm.stopBroadcast();
    }
}
