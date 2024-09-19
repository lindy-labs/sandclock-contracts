// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {scWBTC} from "../src/steth/scWBTC.sol";
import {AaveV3ScWbtcAdapter} from "../src/steth/scWbtc-adapters/AaveV3ScWbtcAdapter.sol";
import {WbtcWethPriceConverter} from "../src/steth/priceConverter/WbtcWethPriceConverter.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {scCrossAssetYieldVault} from "../src/steth/scCrossAssetYieldVault.sol";
import {PriceConverter} from "../src/steth/priceConverter/PriceConverter.sol";
import {ISinglePairPriceConverter} from "../src/steth/priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "../src/steth/swapper/ISinglePairSwapper.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";
import {WbtcWethSwapper} from "../src/steth/swapper/WbtcWethSwapper.sol";

contract scWBTCTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    event Disinvested(uint256 targetTokenAmount);

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 wbtc;

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scWBTC vault;

    AaveV3ScWbtcAdapter aaveV3Adapter;
    ISinglePairSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    uint256 pps;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20733282);

        wbtc = ERC20(C.WBTC);
        weth = WETH(payable(C.WETH));
        aaveV3Adapter = new AaveV3ScWbtcAdapter();

        pps = wethVault.totalAssets().divWadDown(wethVault.totalSupply());

        _deployAndSetUpVault();
    }

    function test_constructor() public {
        assertEq(address(vault.asset()), C.WBTC);
        assertEq(address(vault.targetToken()), address(weth), "target token");
        assertEq(address(vault.targetVault()), address(wethVault), "weth vault");
        assertEq(address(vault.priceConverter()), address(priceConverter), "price converter");
        assertEq(address(vault.swapper()), address(swapper), "swapper");

        assertEq(weth.allowance(address(vault), address(vault.targetVault())), type(uint256).max, "scWETH allowance");
        assertEq(wbtc.allowance(address(vault), address(aaveV3Adapter.pool())), type(uint256).max, "wbtc allowance");
        assertEq(weth.allowance(address(vault), address(aaveV3Adapter.pool())), type(uint256).max, "weth allowance");
    }

    function test_rebalance() public {
        uint256 initialBalance = 1e8;
        uint256 initialDebt = 1 ether;
        deal(address(wbtc), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), initialDebt);

        vault.rebalance(callData);

        assertEq(vault.totalDebt(), initialDebt, "total debt");
        assertEq(vault.totalCollateral(), initialBalance, "total collateral");

        _assertCollateralAndDebt(aaveV3Adapter.id(), initialBalance, initialDebt);

        assertApproxEqRel(wethVault.balanceOf(address(vault)), initialDebt.divWadDown(pps), 1e5, "scETH shares");
    }

    function test_disinvest() public {
        uint256 initialBalance = 10e8;
        uint256 initialDebt = 100 ether;
        deal(address(wbtc), address(vault), initialBalance);
        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), initialDebt);
        vault.rebalance(callData);

        uint256 disinvestAmount = vault.targetTokenInvestedAmount() / 2;
        vm.expectEmit(true, true, true, true);
        emit Disinvested(disinvestAmount - 1);

        vault.disinvest(disinvestAmount);

        assertApproxEqRel(weth.balanceOf(address(vault)), disinvestAmount, 1e2, "weth balance");
        assertApproxEqRel(vault.targetTokenInvestedAmount(), initialDebt - disinvestAmount, 1e2, "weth invested");
    }

    function test_sellProfit() public {
        uint256 initialBalance = 1e8;
        uint256 initialDebt = 10 ether;
        deal(address(wbtc), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), initialDebt);

        vault.rebalance(callData);

        // add profit to the weth vault
        uint256 initialWethInvested = vault.targetTokenInvestedAmount();
        deal(address(weth), address(wethVault), initialWethInvested * 3);

        uint256 assetBalanceBefore = vault.assetBalance();
        uint256 profit = vault.getProfit();

        vm.prank(keeper);
        vault.sellProfit(0);

        uint256 expectedDaiBalance = assetBalanceBefore + priceConverter.targetTokenToAsset(profit);
        _assertCollateralAndDebt(aaveV3Adapter.id(), initialBalance, initialDebt);
        assertApproxEqRel(vault.assetBalance(), expectedDaiBalance, 0.01e18, "asset balance");
        assertApproxEqRel(
            vault.targetTokenInvestedAmount(), initialWethInvested, 0.001e18, "sold more than actual profit"
        );
    }

    function test_withdraw_whenInProfit() public {
        uint256 initialBalance = 10e8;

        _deposit(alice, initialBalance);

        uint256 borrowAmount = priceConverter.assetToTargetToken(initialBalance.mulWadDown(0.6e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), borrowAmount);

        vault.rebalance(callData);

        // add profit to the weth vault
        deal(address(weth), address(wethVault), wethVault.totalAssets() * 2);

        vm.startPrank(alice);
        vault.withdraw(initialBalance / 2, alice, alice);

        // withdraw all the remaining amount
        vault.redeem(vault.balanceOf(alice), alice, alice);

        assertApproxEqAbs(wbtc.balanceOf(alice), initialBalance * 2, 3e7, "alice profits almost doubled");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolAndNoProfit() public {
        uint256 initialBalance = 30e8;
        deal(address(wbtc), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 200 ether);

        vault.rebalance(callData);

        assertEq(vault.getProfit(), 0, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(wbtc.balanceOf(address(vault)), totalBefore, 0.001e18, "vault wbtc balance");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertEq(vault.totalDebt(), 0, "total debt");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenUnderwater() public {
        uint256 initialBalance = 30e8;
        deal(address(wbtc), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 200 ether);

        vault.rebalance(callData);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        vault.exitAllPositions(0);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqRel(wbtc.balanceOf(address(vault)), totalBefore, 0.01e18, "vault wbtc balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenInProfit() public {
        uint256 initialBalance = 30e8;
        deal(address(wbtc), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 200 ether);

        vault.rebalance(callData);

        // simulate 50% profit
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.5e18));

        // assertEq(vault.getProfit(), 100 ether, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(wbtc.balanceOf(address(vault)), totalBefore, 0.005e18, "vault wbtc balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
    }

    /////////////////////////////////// INTERNAL METHODS ////////////////////

    function _deployAndSetUpVault() internal {
        priceConverter = new WbtcWethPriceConverter();
        swapper = new WbtcWethSwapper();

        vault = new scWBTC(address(this), keeper, wethVault, priceConverter, swapper);

        vault.addAdapter(aaveV3Adapter);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    function _assertCollateralAndDebt(uint256 _protocolId, uint256 _expectedCollateral, uint256 _expectedDebt)
        internal
    {
        uint256 collateral = vault.getCollateral(_protocolId);
        uint256 debt = vault.getDebt(_protocolId);
        string memory protocolName = _protocolIdToString(_protocolId);

        assertApproxEqAbs(collateral, _expectedCollateral, 1, string(abi.encodePacked("collateral on ", protocolName)));
        assertApproxEqAbs(debt, _expectedDebt, 1, string(abi.encodePacked("debt on ", protocolName)));
    }

    function _protocolIdToString(uint256 _protocolId) public view returns (string memory) {
        if (_protocolId == aaveV3Adapter.id()) {
            return "Aave V3";
        }

        revert("unknown protocol");
    }

    function _deposit(address _user, uint256 _amount) internal returns (uint256 shares) {
        deal(address(wbtc), _user, _amount);

        vm.startPrank(_user);
        wbtc.safeApprove(address(vault), type(uint256).max);
        shares = vault.deposit(_amount, _user);
        vm.stopPrank();
    }
}
