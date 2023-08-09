// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MainnetDeployBase} from "../../base/MainnetDeployBase.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";

/**
 * A script exercising the reallocate functionality of scUSDCv2 in different situations on a forked mainnet.
 * cmd: forge script script/v2/fork-scenarios/scUSDCv2Reallocate.s.sol --skip-simulation -vv
 */
contract scUSDCv2Reallocate is MainnetDeployBase, Test {
    using FixedPointMathLib for uint256;

    PriceConverter priceConverter;
    scWETHv2 scWethV2;
    scUSDCv2 scUsdcV2;

    IAdapter aaveV3Adapter;
    IAdapter aaveV2Adapter;

    address alice = address(0x0100);

    function run() external {
        _fork(17529069);
        // scUsdcV2 vault deployed with only aaveV2 adapter
        _deployVaults();

        // make a deposit of 1 million USDC from alice
        _depositUsdc(1_000_000e6, alice);

        vm.startBroadcast(keeper);

        // 1. make initial investment to weth vault
        console2.log("\n-- initial investment --");
        _invest();
        _logVaultInfo();
        _logPositions();

        vm.stopBroadcast();

        // 2. add aaveV3 adapter
        console2.log("\n-- add aaveV3 adapter --");
        scUsdcV2.addAdapter(aaveV3Adapter);

        if (!scUsdcV2.isSupported(aaveV3Adapter.id())) revert("aaveV3 adapter is not supported");
        else console2.log("aaveV3 adapter supported");

        // use case 1: we have added a new adapter and want to migrate existing loan to it
        // 3. move whole position from aaveV2 to aaveV3 (reallocate)
        console2.log("\n-- move whole position from aaveV2 to aaveV3 --");
        uint256 debtAmount = scUsdcV2.getDebt(aaveV2Adapter.id());
        uint256 collateralAmount = scUsdcV2.getCollateral(aaveV2Adapter.id());

        bytes[] memory callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scUSDCv2.repay.selector, aaveV2Adapter.id(), debtAmount);
        callData[1] = abi.encodeWithSelector(scUSDCv2.withdraw.selector, aaveV2Adapter.id(), collateralAmount);
        callData[2] = abi.encodeWithSelector(scUSDCv2.supply.selector, aaveV3Adapter.id(), collateralAmount);
        callData[3] = abi.encodeWithSelector(scUSDCv2.borrow.selector, aaveV3Adapter.id(), debtAmount);

        vm.startBroadcast(keeper);

        scUsdcV2.reallocate(debtAmount, callData);
        _logPositions();

        // use case 2: we found out that we could get better rates on aaveV2 but not for the whole loan
        // 4. move some funds back to aaveV2
        console2.log("\n-- move some funds back to aaveV2 --");
        debtAmount = debtAmount / 5;
        collateralAmount = collateralAmount / 5;
        callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scUSDCv2.repay.selector, aaveV3Adapter.id(), debtAmount);
        callData[1] = abi.encodeWithSelector(scUSDCv2.withdraw.selector, aaveV3Adapter.id(), collateralAmount);
        callData[2] = abi.encodeWithSelector(scUSDCv2.supply.selector, aaveV2Adapter.id(), collateralAmount);
        callData[3] = abi.encodeWithSelector(scUSDCv2.borrow.selector, aaveV2Adapter.id(), debtAmount);

        scUsdcV2.reallocate(debtAmount, callData);
        _logPositions();

        vm.stopBroadcast();
    }

    function _fork(uint256 _blockNumber) internal {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(_blockNumber);
    }

    function _deployVaults() internal {
        vm.startBroadcast(deployerAddress);

        Swapper swapper = new Swapper();
        priceConverter = new PriceConverter(deployerAddress);

        scWethV2 = new scWETHv2(deployerAddress, keeper, weth, swapper, priceConverter);
        scUsdcV2 = new scUSDCv2(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        aaveV3Adapter = new AaveV3ScUsdcAdapter();
        aaveV2Adapter = new AaveV2ScUsdcAdapter();

        // skip aave v3 adapter
        scUsdcV2.addAdapter(aaveV2Adapter);

        vm.stopBroadcast();
    }

    function _depositUsdc(uint256 _depositAmount, address _account) internal {
        deal(address(scUsdcV2.asset()), _account, _depositAmount);

        vm.startPrank(_account);
        scUsdcV2.asset().approve(address(scUsdcV2), _depositAmount);
        scUsdcV2.deposit(_depositAmount, _account);
        vm.stopPrank();

        console2.log("\ndeposited %s from %s", _depositAmount, _account);
    }

    function _invest() internal {
        uint256 minFloatRequired = scUsdcV2.totalAssets().mulWadUp(scUsdcV2.floatPercentage());
        uint256 investableAmount = scUsdcV2.usdcBalance() - minFloatRequired;

        uint256 aaveV2TargetDebt = priceConverter.usdcToEth(investableAmount.mulWadDown(0.7e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scUsdcV2.supply.selector, aaveV2Adapter.id(), investableAmount);
        callData[1] = abi.encodeWithSelector(scUsdcV2.borrow.selector, aaveV2Adapter.id(), aaveV2TargetDebt);

        scUsdcV2.rebalance(callData);
    }

    function _logVaultInfo() internal view {
        console2.log("total assets\t\t", scUsdcV2.totalAssets());
        console2.log("total collateral\t", scUsdcV2.totalCollateral());
        console2.log("total debt\t\t", scUsdcV2.totalDebt());
        console2.log("weth invested\t\t", scUsdcV2.wethInvested());
    }

    function _logPositions() internal view {
        console2.log(" - aave v3 -");
        console2.log("collateral\t", scUsdcV2.getCollateral(aaveV3Adapter.id()));
        console2.log("debt\t\t", scUsdcV2.getDebt(aaveV3Adapter.id()));

        console2.log(" - aave v2 -");
        console2.log("collateral\t", scUsdcV2.getCollateral(aaveV2Adapter.id()));
        console2.log("debt\t\t", scUsdcV2.getDebt(aaveV2Adapter.id()));
    }
}
