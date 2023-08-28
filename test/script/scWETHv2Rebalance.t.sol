// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {Errors} from "aave-v3/protocol/libraries/helpers/Errors.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {scWETHv2Rebalance} from "../../script/v2/manual-runs/scWETHv2Rebalance.s.sol";

contract scWETHv2RebalanceTest is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    uint256 mainnetFork;

    scWETHv2Rebalance script;
    // scWETHv2 vault;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18014113);
        script = new scWETHv2Rebalance();
    }

    function testRun() public {
        console2.log(address(script));
        script.run();
    }
}
