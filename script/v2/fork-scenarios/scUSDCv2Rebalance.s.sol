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
 * A script exercising the rebalance functionality of scUSDCv2 in different situations on a forked mainnet.
 * cmd: forge script script/v2/fork-scenarios/scUSDCv2Rebalance.s.sol --skip-simulation -vv
 */
contract scUSDCv2Rebalance is MainnetDeployBase, Test {
    using FixedPointMathLib for uint256;

    PriceConverter priceConverter;
    scWETHv2 scWethV2;
    scUSDCv2 scUsdcV2;

    IAdapter aaveV3Adapter;
    IAdapter aaveV2Adapter;

    address alice = address(0x0100);
    address bob = address(0x0200);

    // allocation percents should add up to 1e18, i.e. 100%
    uint256 aaveV3AllocationPercent = 0.6e18;
    uint256 aaveV2AllocationPercent = 0.4e18;

    uint256 aaveV3TargetLtv = 0.7e18; // 70%
    uint256 aaveV2TargetLtv = 0.5e18; // 50%
    uint256 ltvDiffTolerance = 0.003e18;

    function run() external {
        // _fork(17529069);
        _deployVaults();

        // make a deposit of 1 million USDC from alice
        // _depositUsdc(1_000_000e6, alice);

        // vm.startBroadcast(keeper);

        // // 1. make initial investment to weth vault
        // console2.log("\n-- initial investment --");
        // _invest();
        // _assertLtvsAreAtTarget();
        // _logVaultInfo();

        // // warp time to change the ltvs
        // vm.warp(block.timestamp + 365 days);
        // console2.log("\n-- ltvs changed after 356 days --");
        // _assertLtvsAreAboveTarget();
        // _logVaultInfo();

        // // 2. rebalance to the target ltv
        // _rebalance();
        // console2.log("\n-- rebalance to get ltvs to target values --");
        // _assertLtvsAreAtTarget();
        // _logVaultInfo();

        // vm.stopBroadcast();

        // // make a deposit of 200k USDC from bob
        // _depositUsdc(200_000e6, bob);

        // // 3. rebalance to reinvest the additional deposit
        // vm.startBroadcast(keeper);
        // console2.log("\n-- reinvest additional deposits --");
        // _invest();
        // _assertLtvsAreAtTarget();
        // _logVaultInfo();
        // vm.stopBroadcast();

        // // add 10% to the scWETH vault to simulate profits from staking
        // ERC20 weth = scWethV2.asset();
        // deal(address(weth), address(scWethV2), weth.balanceOf(address(scWethV2)).mulWadUp(1.1e18));

        // // 4. sell profit and reinvest
        // vm.startBroadcast(keeper);
        // console2.log("\n-- sell & reinvest profits --");
        // // note: selling profits can be done as part of the rebalance call (added to multicall data) but usdc received from selling will has to be estimated in that case
        // scUsdcV2.sellProfit(0); // _usdcAmountOutMin = 0
        // _invest();
        // _assertLtvsAreAtTarget();
        // _logVaultInfo();
    }

    function _fork(uint256 _blockNumber) internal {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(_blockNumber);
    }

    function _deployVaults() internal {
        vm.startBroadcast(deployerPrivateKey);

        Swapper swapper = new Swapper();
        priceConverter = new PriceConverter(deployerAddress);

        scWethV2 = new scWETHv2(deployerAddress, keeper, weth, swapper, priceConverter);
        console2.log("scWethV2:", address(scWethV2));
        scUsdcV2 = new scUSDCv2(deployerAddress, keeper, scWethV2, priceConverter, swapper);
        console2.log("scUSDCV2:", address(scUsdcV2));

        aaveV2Adapter = new AaveV2ScUsdcAdapter();
        aaveV3Adapter = new AaveV3ScUsdcAdapter();

        scUsdcV2.addAdapter(aaveV2Adapter);
        scUsdcV2.addAdapter(aaveV3Adapter);

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

        uint256 aaveV3Collaateral = investableAmount.mulWadDown(aaveV3AllocationPercent);
        uint256 aaveV3TargetDebt = priceConverter.usdcToEth(aaveV3Collaateral.mulWadDown(aaveV3TargetLtv));

        uint256 aaveV2Collaateral = investableAmount.mulWadDown(aaveV2AllocationPercent);
        uint256 aaveV2TargetDebt = priceConverter.usdcToEth(aaveV2Collaateral.mulWadDown(aaveV2TargetLtv));

        bytes[] memory callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scUsdcV2.supply.selector, aaveV3Adapter.id(), aaveV3Collaateral);
        callData[1] = abi.encodeWithSelector(scUsdcV2.borrow.selector, aaveV3Adapter.id(), aaveV3TargetDebt);
        callData[2] = abi.encodeWithSelector(scUsdcV2.supply.selector, aaveV2Adapter.id(), aaveV2Collaateral);
        callData[3] = abi.encodeWithSelector(scUsdcV2.borrow.selector, aaveV2Adapter.id(), aaveV2TargetDebt);

        scUsdcV2.rebalance(callData);
    }

    function _rebalance() internal {
        uint256 aaveV3Ltv = _getLtv(aaveV3Adapter.id());
        uint256 aaveV2Ltv = _getLtv(aaveV2Adapter.id());

        uint256 aaveV3ltvDelta = aaveV3Ltv - aaveV3TargetLtv;
        uint256 aaveV2ltvDelta = aaveV2Ltv - aaveV2TargetLtv;

        // we need to repay the debt to get to the target ltv
        uint256 aaveV3repayAmount = aaveV3ltvDelta.mulWadUp(scUsdcV2.getDebt(aaveV3Adapter.id()));
        uint256 aaveV2repayAmount = aaveV2ltvDelta.mulWadUp(scUsdcV2.getDebt(aaveV2Adapter.id()));

        // make sure the mimimum float is maintained after the rebalance otherwise rebalance will revert
        uint256 minFloatRequired = scUsdcV2.totalAssets().mulWadUp(scUsdcV2.floatPercentage());
        uint256 floatDelta = minFloatRequired - scUsdcV2.usdcBalance();

        // include the float delta in the repay amount
        uint256 repayAmount = aaveV3repayAmount + aaveV2repayAmount + floatDelta;

        // create the multicall data for the rebalance, i.e. disinvest from scWETH, repay debt, and withdraw collateral maintain min float
        bytes[] memory callData = new bytes[](5);
        callData[0] = abi.encodeWithSelector(scUSDCv2.disinvest.selector, repayAmount);
        callData[1] = abi.encodeWithSelector(scUSDCv2.repay.selector, aaveV3Adapter.id(), aaveV3repayAmount);
        callData[2] = abi.encodeWithSelector(scUSDCv2.withdraw.selector, aaveV3Adapter.id(), floatDelta / 2);
        callData[3] = abi.encodeWithSelector(scUSDCv2.repay.selector, aaveV2Adapter.id(), aaveV2repayAmount);
        callData[4] = abi.encodeWithSelector(scUSDCv2.withdraw.selector, aaveV2Adapter.id(), floatDelta / 2);

        scUsdcV2.rebalance(callData);
    }

    function _assertLtvsAreAtTarget() internal view {
        uint256 aaveV3Ltv = _getLtv(aaveV3Adapter.id());
        uint256 aaveV2Ltv = _getLtv(aaveV2Adapter.id());

        console2.log("aave V3 ltv\t\t", aaveV3Ltv);
        console2.log("aave V2 ltv\t\t", aaveV2Ltv);

        require(aaveV3Ltv <= aaveV3TargetLtv + ltvDiffTolerance, "aave V3 ltv greater than target");
        require(aaveV2Ltv <= aaveV2TargetLtv + ltvDiffTolerance, "aave V2 ltv greater than target");
    }

    function _assertLtvsAreAboveTarget() internal view {
        uint256 aaveV3Ltv = _getLtv(aaveV3Adapter.id());
        uint256 aaveV2Ltv = _getLtv(aaveV2Adapter.id());

        console2.log("aave V3 ltv\t\t", aaveV3Ltv);
        console2.log("aave V2 ltv\t\t", aaveV2Ltv);

        require(aaveV3Ltv > aaveV3TargetLtv + ltvDiffTolerance, "aave V3 ltv lower than target");
        require(aaveV2Ltv > aaveV2TargetLtv + ltvDiffTolerance, "aave V2 ltv lower than target");
    }

    function _getLtv(uint256 adapterId) internal view returns (uint256) {
        return priceConverter.ethToUsdc(scUsdcV2.getDebt(adapterId)).divWadUp(scUsdcV2.getCollateral(adapterId));
    }

    function _logVaultInfo() internal view {
        console2.log("total assets\t\t", scUsdcV2.totalAssets());
        console2.log("total collateral\t", scUsdcV2.totalCollateral());
        console2.log("total debt\t\t", scUsdcV2.totalDebt());
        console2.log("weth invested\t\t", scUsdcV2.wethInvested());
    }
}
