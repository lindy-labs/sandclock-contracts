// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ICREATE3Factory} from "create3-factory/ICREATE3Factory.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {MainnetAddresses as MA} from "script/base/MainnetAddresses.sol";
import {scUSDSv2} from "src/steth/scUSDSv2.sol";
import {DeployScUsdsV2} from "script/v2/deploy/DeployScUsdsV2.s.sol";
import {DaiWethPriceConverter} from "src/steth/priceConverter/DaiWethPriceConverter.sol";
import {UsdsWethSwapper} from "src/steth/swapper/UsdsWethSwapper.sol";

contract DeployScUsdsV2Test is Test {
    DeployScUsdsV2 script;

    address deployerAddress;
    ICREATE3Factory create3 = ICREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21072810);

        uint256 deployerPrivateKey = uint256(keccak256("privateKey"));

        deployerAddress = vm.addr(deployerPrivateKey);
    }

    function test_run_deploysScUsdsV2ContractUsingCreate3() public {
        // setup

        script = new DeployScUsdsTestHarness(deployerAddress);
        address expected = script.getCreate3Contract(deployerAddress, type(scUSDSv2).name);
        address expectedPriceConverter = script.getCreate3Contract(deployerAddress, type(DaiWethPriceConverter).name);
        address expectedSwapper = script.getCreate3Contract(deployerAddress, type(UsdsWethSwapper).name);
        deal(deployerAddress, 10 ether);

        // deploy
        scUSDSv2 deployed = script.run();

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

contract DeployScUsdsTestHarness is DeployScUsdsV2 {
    constructor(address _deployerAddress) {
        deployerAddress = _deployerAddress;
        keeper = MA.KEEPER;
        multisig = MA.MULTISIG;
    }

    function _init() internal override {
        // override to prevent reading env variables
    }
}
