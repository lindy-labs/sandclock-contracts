// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {RewardTracker} from "src/staking/RewardTracker.sol";
import {MainnetAddresses as MA} from "script/base/MainnetAddresses.sol";
import {DeployStaking} from "script/DeployStaking.s.sol";

contract DeployStakingTest is Test {
    using FixedPointMathLib for uint256;

    DeployStaking deployStaking;

    uint256 deployerPrivateKey = uint256(keccak256("privateKey"));
    address deployer = vm.addr(deployerPrivateKey);
    address distributor = address(0x123);
    address treasury = address(0x456);

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18488739);
    }

    function test_run_deploysStaking() public {
        // setup
        deployStaking = new DeployStakingTestHarness(deployerPrivateKey, distributor, treasury);
        address expected = deployStaking.getCreate3Contract(deployer, "RewardTracker");

        // deploy
        RewardTracker deployed = deployStaking.run();

        // assert
        assertEq(address(deployed), expected, "deployed address");

        assertTrue(deployed.hasRole(deployed.DEFAULT_ADMIN_ROLE(), deployer), "admin role");
        assertTrue(deployed.hasRole(deployed.DISTRIBUTOR(), distributor), "distributor role");
        assertEq(deployed.treasury(), treasury, "treasury");
        assertEq(address(deployed.rewardToken()), C.WETH, "reward token");
        assertEq(address(deployed.asset()), MA.QUARTZ, "stake token");
        assertEq(deployed.name(), deployStaking.NAME(), "name");
        assertEq(deployed.symbol(), deployStaking.SYMBOL(), "symbol");
        assertEq(deployed.duration(), deployStaking.DURATION(), "duration");

        assertTrue(deployed.isVault(MA.SCWETHV2), "scWethV2 vault not added");
    }

    function test_run_failsIfAlreadyDeployed() public {
        deployStaking = new DeployStakingTestHarness(deployerPrivateKey, distributor, treasury);

        deployStaking.run();

        // try to deploy again
        vm.expectRevert("DEPLOYMENT_FAILED");
        deployStaking.run();
    }
}

contract DeployStakingTestHarness is DeployStaking {
    constructor(uint256 _deployerPrivateKey, address _distributor, address _treasury) DeployStaking() {
        deployerPrivateKey = _deployerPrivateKey;
        distributor = _distributor;
        treasury = _treasury;
    }

    function _init() internal override {
        // override to prevent reading env variables
    }
}
