// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ICREATE3Factory} from "create3-factory/ICREATE3Factory.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {MainnetAddresses as MA} from "script/base/MainnetAddresses.sol";
import {scUSDT} from "src/steth/scUSDT.sol";
import {UsdtWethSwapper} from "src/steth/swapper/UsdtWethSwapper.sol";
import {UsdtWethPriceConverter} from "src/steth/priceConverter/UsdtWethPriceConverter.sol";
import {DeployScUsdt} from "script/v2/deploy/DeployScUsdt.s.sol";

contract DeployScUsdtTest is Test {
    using FixedPointMathLib for uint256;

    DeployScUsdt script;

    address deployerAddress;
    ICREATE3Factory create3 = ICREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20068274);

        uint256 deployerPrivateKey = uint256(keccak256("privateKey"));

        deployerAddress = vm.addr(deployerPrivateKey);
    }

    function test_run_deploysScUsdtContractUsingCreate3() public {
        // setup

        script = new DeployScUsdtTestHarness(deployerAddress);
        address expected = script.getCreate3Contract(deployerAddress, type(scUSDT).name);
        address swapper = script.getCreate3Contract(deployerAddress, type(UsdtWethSwapper).name);
        address priceConverter = script.getCreate3Contract(deployerAddress, type(UsdtWethPriceConverter).name);
        deal(deployerAddress, 10 ether);

        // deploy
        scUSDT deployed = script.run();

        // assert
        assertEq(address(deployed), expected, "deployed address");
        assertTrue(address(deployed).code.length != 0, "contract code");
        assertTrue(deployed.hasRole(deployed.DEFAULT_ADMIN_ROLE(), MA.MULTISIG), "admin role");
        assertTrue(deployed.hasRole(deployed.KEEPER_ROLE(), MA.KEEPER), "keeper role");
        assertTrue(deployed.totalAssets() > 0, "total assets = 0, no initial deposit made");
        assertTrue(deployed.isSupported(1), "adapter not added");
        assertEq(address(deployed.swapper()), swapper, "swapper");
        assertEq(address(deployed.priceConverter()), priceConverter, "price converter");
        assertEq(address(deployed.targetVault()), MA.SCWETHV2, "target vault");
    }
}

contract DeployScUsdtTestHarness is DeployScUsdt {
    constructor(address _deployerAddress) {
        deployerAddress = _deployerAddress;
        keeper = MA.KEEPER;
        multisig = MA.MULTISIG;
    }

    function _init() internal override {
        // override to prevent reading env variables
    }
}
