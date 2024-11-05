// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {scUSDSv2} from "../src/steth/scUSDSv2.sol";
import {AaveV3ScUsdsAdapter} from "../src/steth/scUsds-adapters/AaveV3ScUsdsAdapter.sol";
import {DaiWethPriceConverter} from "../src/steth/priceConverter/DaiWethPriceConverter.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {scCrossAssetYieldVault} from "../src/steth/scCrossAssetYieldVault.sol";
import {ISinglePairPriceConverter} from "../src/steth/priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "../src/steth/swapper/ISinglePairSwapper.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";
import {UsdsWethSwapper} from "../src/steth/swapper/UsdsWethSwapper.sol";

contract scUSDSv2Test is Test {
    using Address for address;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    event Disinvested(uint256 targetTokenAmount);

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usds;

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scUSDSv2 vault;

    AaveV3ScUsdsAdapter aaveV3Adapter;
    ISinglePairSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    uint256 pps;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21072810);

        usds = ERC20(C.USDS);
        weth = WETH(payable(C.WETH));
        aaveV3Adapter = new AaveV3ScUsdsAdapter();

        pps = wethVault.totalAssets().divWadDown(wethVault.totalSupply());

        _deployAndSetUpVault();
    }

    function test_constructor() public {
        assertEq(address(vault.asset()), C.USDS);
        assertEq(address(vault.targetToken()), address(weth), "target token");
        assertEq(address(vault.targetVault()), address(wethVault), "weth vault");
        assertEq(address(vault.priceConverter()), address(priceConverter), "price converter");
        assertEq(address(vault.swapper()), address(swapper), "swapper");

        assertEq(weth.allowance(address(vault), address(vault.targetVault())), type(uint256).max, "scWETH allowance");
        assertEq(usds.allowance(address(vault), address(aaveV3Adapter.pool())), type(uint256).max, "usds allowance");
        assertEq(weth.allowance(address(vault), address(aaveV3Adapter.pool())), type(uint256).max, "weth allowance");
    }

    function test_rebalance() public {
        uint256 initialBalance = 1_000_000e18;
        uint256 initialDebt = 100 ether;
        deal(address(usds), address(vault), initialBalance);

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
        uint256 initialBalance = 1_000_000e18;
        uint256 initialDebt = 100 ether;
        deal(address(usds), address(vault), initialBalance);
        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), initialDebt);
        vault.rebalance(callData);

        uint256 disinvestAmount = vault.targetTokenInvestedAmount() / 2;
        vault.disinvest(disinvestAmount);

        assertApproxEqRel(weth.balanceOf(address(vault)), disinvestAmount, 1e2, "weth balance");
        assertApproxEqRel(vault.targetTokenInvestedAmount(), initialDebt - disinvestAmount, 1e2, "weth invested");
    }

    function test_sellProfit() public {
        uint256 initialBalance = 100000e18;
        uint256 initialDebt = 10 ether;
        deal(address(usds), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), initialDebt);

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.targetTokenInvestedAmount();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 usdsBalanceBefore = vault.assetBalance();
        uint256 profit = vault.getProfit();

        vm.prank(keeper);
        vault.sellProfit(0);

        uint256 expectedDaiBalance = usdsBalanceBefore + priceConverter.targetTokenToAsset(profit);
        _assertCollateralAndDebt(aaveV3Adapter.id(), initialBalance, initialDebt);
        assertApproxEqRel(vault.assetBalance(), expectedDaiBalance, 0.01e18, "usds balance");
        assertApproxEqRel(
            vault.targetTokenInvestedAmount(), initialWethInvested, 0.001e18, "sold more than actual profit"
        );
    }

    function test_withdrawFunds() public {
        uint256 initialBalance = 1_000_000e18;
        _deposit(alice, initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 100 ether);

        vault.rebalance(callData);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usds.balanceOf(alice), withdrawAmount, "alice asset balance");
    }

    function testFuzz_withdraw_whenInProfit(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = 0;
        _amount = bound(_amount, 1e18, 10_000_000e18); // upper limit constrained by weth available on aave v3
        deal(address(usds), alice, _amount);

        vm.startPrank(alice);
        usds.approve(address(vault), type(uint256).max);
        vault.deposit(_amount, alice);
        vm.stopPrank();

        uint256 borrowAmount = priceConverter.assetToTargetToken(_amount.mulWadDown(0.7e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), _amount);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), borrowAmount);

        vault.rebalance(callData);

        // add 10% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.1e18));

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e18, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, total.mulWadDown(0.001e18), "total assets");
        assertApproxEqAbs(usds.balanceOf(alice), _withdrawAmount, _amount.mulWadDown(0.001e18), "usds balance");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralNoProfit() public {
        uint256 initialBalance = 10_000e18;
        deal(address(usds), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 2 ether);

        vault.rebalance(callData);

        assertEq(vault.getProfit(), 0, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(vault.assetBalance(), totalBefore, 0.001e18, "vault asset balance");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertEq(vault.totalDebt(), 0, "total debt");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenUnderwater() public {
        uint256 initialBalance = 1000000e18;
        deal(address(usds), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 100 ether);

        vault.rebalance(callData);

        // simulate 50% loss
        deal(address(weth), address(wethVault), 95 ether);

        uint256 totalBefore = vault.totalAssets();

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        vault.exitAllPositions(0);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqRel(vault.assetBalance(), totalBefore, 0.02e18, "vault usds balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenInProfit() public {
        uint256 initialBalance = 1_000_000e18;
        deal(address(usds), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 100 ether);

        vault.rebalance(callData);

        // simulate profit
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.5e18));

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(vault.assetBalance(), totalBefore, 0.2e18, "vault usds balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
    }

    function test_claimRewards() public {
        uint256 initialBalance = 1_000_000e18;
        _deposit(address(this), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3Adapter.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3Adapter.id(), 100 ether);

        vault.rebalance(callData);

        ERC20 aUsds = ERC20(C.AAVE_V3_AUSDS_TOKEN);
        uint256 initialAUsdsBalance = aUsds.balanceOf(address(vault));
        uint256 initialCollateral = vault.totalCollateral();

        vm.warp(block.timestamp + 30 days);

        // the vault gets aUsds Rewards
        vault.claimRewards(aaveV3Adapter.id(), "");

        uint256 newCollateral = vault.totalCollateral();
        uint256 newAUsdsBalance = aUsds.balanceOf(address(vault));

        assertGt(newCollateral, initialCollateral, "collateral did not increase");
        assertGt(newAUsdsBalance, initialAUsdsBalance, "no aUsds rewards");
    }

    ///////////////////////////////// INTERNAL METHODS /////////////////////////////////

    function _deposit(address _user, uint256 _amount) public returns (uint256 shares) {
        deal(address(usds), _user, _amount);

        vm.startPrank(_user);
        usds.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _user);
        vm.stopPrank();
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

    function _deployAndSetUpVault() internal {
        priceConverter = new DaiWethPriceConverter();
        swapper = new UsdsWethSwapper();

        vault = new scUSDSv2(address(this), keeper, wethVault, priceConverter, swapper);

        vault.addAdapter(aaveV3Adapter);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    function _protocolIdToString(uint256 _protocolId) public view returns (string memory) {
        if (_protocolId == aaveV3Adapter.id()) {
            return "Aave V3 Adapter";
        }

        revert("unknown protocol");
    }
}
