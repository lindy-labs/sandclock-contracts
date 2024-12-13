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
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {RebalanceScWethV2} from "script/v2/keeper-actions/RebalanceScWethV2.s.sol";
import {ExitAllPositionsScWethV2} from "script/v2/keeper-actions/ExitAllPositionsScWethV2.s.sol";

import {scWETHv2} from "src/steth/scWETHv2.sol";
import {IAdapter} from "src/steth/IAdapter.sol";

contract ExitAllPositionsScWETHv2Test is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    uint256 mainnetFork;

    RebalanceScWethV2TestHarness rebalanceScript;
    ExitAllPositionsScWethV2 exitScript;
    scWETHv2 vault;
    WETH weth = WETH(payable(C.WETH));

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18018649);
        rebalanceScript = new RebalanceScWethV2TestHarness();
        exitScript = new ExitAllPositionsScWethV2();
        vault = exitScript.vault();

        // update roles to latest accounts
        vm.startPrank(MainnetAddresses.OLD_MULTISIG);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), MainnetAddresses.MULTISIG);
        vault.grantRole(vault.KEEPER_ROLE(), MainnetAddresses.KEEPER);
        vm.stopPrank();
    }

    function testScriptExitsAllPositions(uint256 amount) public {
        amount = bound(amount, 15 ether, 100 ether);
        vault.deposit{value: amount}(address(this));

        // run rebalance script to invest
        rebalanceScript.run();

        uint256 float = weth.balanceOf(address(vault));

        assertApproxEqRel(
            vault.totalAssets() - float, amount - vault.minimumFloatAmount(), 0.005e18, "Investment failure"
        );

        assertGe(vault.totalCollateral(), amount, "totalCollateral error");
        assertGe(vault.totalDebt(), amount, "totalDebt error");

        // exit all positions
        exitScript.run();

        assertApproxEqRel(weth.balanceOf(address(vault)), amount, 0.005e18, "exit Positions fail");
        assertLt(vault.totalCollateral(), 10, "collateral not zero");
        assertLt(vault.totalDebt(), 10, "debt not zero");
    }
}

contract RebalanceScWethV2TestHarness is RebalanceScWethV2 {
    bytes testSwapData;

    function getSwapData(uint256, address, address) public view override returns (bytes memory swapData) {
        return testSwapData;
    }
}
