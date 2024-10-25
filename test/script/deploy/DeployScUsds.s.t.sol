// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ICREATE3Factory} from "create3-factory/ICREATE3Factory.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {MainnetAddresses as MA} from "script/base/MainnetAddresses.sol";
import {scUSDS} from "src/steth/scUSDS.sol";
import {DeployScUsds} from "script/v2/deploy/DeployScUsds.s.sol";

contract DeployScUsdsTest is Test {
    DeployScUsds script;

    address deployerAddress;
    ICREATE3Factory create3 = ICREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21031368);

        uint256 deployerPrivateKey = uint256(keccak256("privateKey"));

        deployerAddress = vm.addr(deployerPrivateKey);
    }

    function test_run_deploysScUsdsContractUsingCreate3() public {
        // setup

        script = new DeployScUsdsTestHarness(deployerAddress);
        address expected = script.getCreate3Contract(deployerAddress, type(scUSDS).name);
        deal(deployerAddress, 10 ether);

        // deploy
        scUSDS deployed = script.run();

        // assert
        assertEq(address(deployed), expected, "deployed address");
        assertTrue(address(deployed).code.length != 0, "contract code");
        assertTrue(deployed.totalAssets() > 0, "total assets = 0, no initial deposit made");
        assertEq(address(deployed.scsDai()), MA.SCSDAI, "target vault");
    }
}

contract DeployScUsdsTestHarness is DeployScUsds {
    constructor(address _deployerAddress) {
        deployerAddress = _deployerAddress;
    }

    function _init() internal override {
        // override to prevent reading env variables
    }
}
