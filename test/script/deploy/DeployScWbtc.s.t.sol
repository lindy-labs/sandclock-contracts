// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ICREATE3Factory} from "create3-factory/ICREATE3Factory.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {MainnetAddresses as MA} from "script/base/MainnetAddresses.sol";
import {scWBTC} from "src/steth/scWBTC.sol";
import {DeployScWbtc} from "script/v2/deploy/DeployScWbtc.s.sol";
import {WbtcWethPriceConverter} from "src/steth/priceConverter/WbtcWethPriceConverter.sol";
import {WbtcWethSwapper} from "src/steth/swapper/WbtcWethSwapper.sol";

contract DeployScWbtcTest is Test {
    DeployScWbtc script;

    address deployerAddress;
    ICREATE3Factory create3 = ICREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21072810);

        uint256 deployerPrivateKey = uint256(keccak256("privateKey"));

        deployerAddress = vm.addr(deployerPrivateKey);
    }

    function test_run_deploysScWbtcContractUsingCreate3() public {
        // setup
        script = new DeployScWbtcTestHarness(deployerAddress);
        address expected = script.getCreate3Contract(deployerAddress, type(scWBTC).name);
        address expectedPriceConverter = script.getCreate3Contract(deployerAddress, type(WbtcWethPriceConverter).name);
        address expectedSwapper = script.getCreate3Contract(deployerAddress, type(WbtcWethSwapper).name);
        deal(deployerAddress, 10 ether);

        // deploy
        scWBTC deployed = script.run();

        // assert
        assertEq(address(deployed), expected, "deployed address");
        assertTrue(address(deployed).code.length != 0, "contract code");
        assertTrue(deployed.totalAssets() > 0, "total assets = 0, no initial deposit made");
        assertEq(address(deployed.targetVault()), MA.SCWETHV2, "target vault");

        assertEq(address(deployed), expected, "deployed address");
        assertTrue(address(deployed).code.length != 0, "contract code");
        assertTrue(deployed.hasRole(deployed.DEFAULT_ADMIN_ROLE(), MA.MULTISIG), "admin role");
        assertTrue(deployed.hasRole(deployed.KEEPER_ROLE(), MA.KEEPER), "keeper role");
        assertTrue(deployed.totalAssets() > 0, "total assets = 0, no initial deposit made");
        assertTrue(deployed.isSupported(1), "adapter not added");
        assertEq(address(deployed.swapper()), expectedSwapper, "swapper");
        assertEq(address(deployed.priceConverter()), expectedPriceConverter, "price converter");
        assertEq(address(deployed.targetVault()), MA.SCWETHV2, "target vault");
    }
}

contract DeployScWbtcTestHarness is DeployScWbtc {
    constructor(address _deployerAddress) {
        deployerAddress = _deployerAddress;
        keeper = MA.KEEPER;
        multisig = MA.MULTISIG;
    }

    function _init() internal override {
        // override to prevent reading env variables
    }
}
