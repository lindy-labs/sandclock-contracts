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

import {Constants as C} from "../../src/lib/Constants.sol";
import {scWETHv2} from "../../src/phase-2/scWETHv2.sol";
// import {LendingMarketManager} from "../../src/phase-2/LendingMarketManager.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../../src/interfaces/balancer/IVault.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../../src/sc4626.sol";
import {scWETHv2Helper} from "../../src/phase-2/scWETHv2Helper.sol";
import {OracleLib} from "../../src/phase-2/OracleLib.sol";
import "../../src/errors/scErrors.sol";

import {IAdapter} from "../../src/scWeth-adapters/IAdapter.sol";
import {AaveV3Adapter} from "../../src/scWeth-adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../../src/scWeth-adapters/CompoundV3Adapter.sol";
import {EulerAdapter} from "../../src/scWeth-adapters/EulerAdapter.sol";

contract scWETHv2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1.5 ether; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETHv2 vault;
    scWETHv2Helper vaultHelper;
    OracleLib oracleLib;
    uint256 initAmount = 100e18;

    uint256 aaveV3AllocationPercent = 0.5e18;
    uint256 eulerAllocationPercent = 0.3e18;
    uint256 compoundAllocationPercent = 0.2e18;

    uint256 slippageTolerance = 0.99e18;
    uint256 maxLtv;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    AggregatorV3Interface public stEThToEthPriceFeed;
    uint256 minimumFloatAmount;

    mapping(IAdapter => uint256) targetLtv;

    uint8 aaveV3AdapterId;
    uint8 eulerAdapterId;
    uint8 compoundV3AdapterId;

    IAdapter aaveV3Adapter;
    IAdapter eulerAdapter;
    IAdapter compoundV3Adapter;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16784444);

        oracleLib = _deployOracleLib();
        scWETHv2.ConstructorParams memory params = _createDefaultWethv2VaultConstructorParams(oracleLib);
        vault = new scWETHv2(params);
        vaultHelper = new scWETHv2Helper(vault, oracleLib);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();
        stEThToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED);
        minimumFloatAmount = vault.minimumFloatAmount();

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        _setupAdapters();

        targetLtv[aaveV3Adapter] = 0.7e18;
        targetLtv[eulerAdapter] = 0.5e18;
        targetLtv[compoundV3Adapter] = 0.7e18;
    }

    function _setupAdapters() internal {
        // add adaptors
        aaveV3Adapter = new AaveV3Adapter();
        eulerAdapter = new EulerAdapter();
        compoundV3Adapter = new CompoundV3Adapter();

        vault.addAdapter(address(aaveV3Adapter));
        vault.addAdapter(address(eulerAdapter));
        vault.addAdapter(address(compoundV3Adapter));

        aaveV3AdapterId = aaveV3Adapter.id();
        eulerAdapterId = eulerAdapter.id();
        compoundV3AdapterId = compoundV3Adapter.id();
    }

    function test_constructor() public {
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true, "admin role not set");
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), keeper), true, "keeper role not set");
        assertEq(address(vault.weth()), C.WETH);
        assertEq(address(vault.stEth()), C.STETH);
        assertEq(address(vault.wstETH()), C.WSTETH);
        assertEq(address(vault.curvePool()), C.CURVE_ETH_STETH_POOL);
        assertEq(address(vault.balancerVault()), C.BALANCER_VAULT);
        assertEq(vault.slippageTolerance(), slippageTolerance);
    }

    function test_setSlippageTolerance() public {
        vault.setSlippageTolerance(0.5e18);
        assertEq(vault.slippageTolerance(), 0.5e18, "slippageTolerance not set");

        // revert if called by another user
        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        vault.setSlippageTolerance(0.5e18);

        vm.expectRevert(InvalidSlippageTolerance.selector);
        vault.setSlippageTolerance(1.1e18);
    }

    function test_setStEThToEthPriceFeed() public {
        address newStEthPriceFeed = alice;
        oracleLib.setStEThToEthPriceFeed(newStEthPriceFeed);
        assertEq(address(oracleLib.stEThToEthPriceFeed()), newStEthPriceFeed);

        // revert if called by another user
        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        oracleLib.setStEThToEthPriceFeed(newStEthPriceFeed);

        vm.expectRevert(ZeroAddress.selector);
        oracleLib.setStEThToEthPriceFeed(address(0x00));
    }

    function test_setMinimumFloatAmount() public {
        uint256 newMinimumFloatAmount = 69e18;
        vault.setMinimumFloatAmount(newMinimumFloatAmount);
        assertEq(vault.minimumFloatAmount(), newMinimumFloatAmount);

        // revert if called by another user
        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        vault.setMinimumFloatAmount(newMinimumFloatAmount);
    }

    function test_receiveFlashLoan_InvalidFlashLoanCaller() public {
        address[] memory empty;
        uint256[] memory amounts = new uint[](1);
        amounts[0] = 1;
        vm.expectRevert(InvalidFlashLoanCaller.selector);
        vault.receiveFlashLoan(empty, amounts, amounts, abi.encode(1));
    }

    function test_receiveFlashLoan_FailsIfInitiatorIsNotVault() public {
        IVault balancer = IVault(C.BALANCER_VAULT);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        tokens[0] = address(weth);
        amounts[0] = 100e18;

        vm.expectRevert(InvalidFlashLoanCaller.selector);
        balancer.flashLoan(address(vault), tokens, amounts, abi.encode(0, 0));
    }

    function test_withdraw_revert() public {
        vm.expectRevert(PleaseUseRedeemMethod.selector);
        vault.withdraw(1e18, address(this), address(this));
    }

    function test_invest_FloatBalanceTooSmall(uint256 amount) public {
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount + 1;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        // deposit into strategy
        vm.startPrank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(FloatBalanceTooSmall.selector, minimumFloatAmount - 1, minimumFloatAmount)
        );
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");
    }

    function test_invest_TooMuch(uint256 amount) public {
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount + 1;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        // deposit into strategy
        vm.startPrank(keeper);
        vm.expectRevert(InsufficientDepositBalance.selector);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");
    }

    function test_deposit_eth(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e21);
        vm.deal(address(this), amount);

        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(address(this).balance, amount);

        vault.deposit{value: amount}(address(this));

        assertEq(address(this).balance, 0, "eth not transferred from user");
        assertEq(vault.balanceOf(address(this)), amount, "shares not minted");
        assertEq(weth.balanceOf(address(vault)), amount, "weth not transferred to vault");

        vm.expectRevert("ZERO_SHARES");
        vault.deposit{value: 0}(address(this));
    }

    // function test_maxLtv() public {
    //     assertEq(lendingManager.getMaxLtv(aaveV3Adapter), 0.9e18, "aaveV3 Max Ltv Error");
    //     assertEq(lendingManager.getMaxLtv(eulerAdapter), 0.7735e18, "euler Max Ltv Error");
    //     assertEq(
    //         lendingManager.getMaxLtv(compoundV3Adapter), 0.9e18, "compoundV3 Max Ltv Error"
    //     );
    // }

    function test_deposit_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        vault.deposit(amount, address(this));

        _floatCheck();
        _depositChecks(amount, preDepositBal);

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        _redeemChecks(preDepositBal);
    }

    function test_redeem_by_others(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        uint256 giftAmount;
        giftAmount = bound(giftAmount, 1, amount - 1);
        vault.approve(alice, giftAmount);

        vm.startPrank(alice);
        vault.redeem(giftAmount, alice, address(this));
        assertEq(vault.totalAssets(), amount - giftAmount);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(weth.balanceOf(address(alice)), giftAmount);

        vm.expectRevert();
        vault.redeem(giftAmount, alice, address(this)); // no shares anymore
    }

    function test_redeem_zero() public {
        vm.expectRevert("ZERO_ASSETS");
        vault.redeem(0, address(this), address(this));
    }

    function test_invest_basic(uint256 amount) public {
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams, uint256 totalSupplyAmount, uint256 totalDebtTaken) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        // deposit into strategy
        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");
        _floatCheck();

        _investChecks(investAmount, oracleLib.wstEthToEth(totalSupplyAmount), totalDebtTaken);
    }

    function test_deposit_invest_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        uint256 shares = _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        // deposit into strategy
        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        assertApproxEqRel(vault.totalAssets(), amount, 0.01e18, "totalAssets error");
        assertEq(vault.balanceOf(address(this)), shares, "shares error");
        assertApproxEqRel(vault.convertToAssets(shares), amount, 0.01e18, "convertToAssets error");

        vault.redeem(shares, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.balanceOf(address(this)), 0, "shares after redeem error");
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0, "convertToAssets after redeem error");
        assertApproxEqRel(weth.balanceOf(address(this)), amount, 0.015e18, "weth balance after redeem error");
    }

    function test_withdrawToVault(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        uint256 maxAssetsDelta = 0.01e18;
        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        // deposit into strategy
        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        uint256 assets = vault.totalCollateral() - vault.totalDebt();
        uint256 floatBalance = amount - investAmount;

        assertEq(weth.balanceOf(address(vault)), floatBalance, "float amount error");

        uint256 ltv = vaultHelper.getLtv();
        uint256 lev = vaultHelper.getLeverage();

        hoax(keeper);
        vault.withdrawToVault(assets / 2);

        _floatCheck();

        // net ltv and leverage must not change after withdraw
        assertApproxEqRel(vaultHelper.getLtv(), ltv, 0.001e18, "ltv changed after withdraw");
        assertApproxEqRel(vaultHelper.getLeverage(), lev, 0.001e18, "leverage changed after withdraw");
        assertApproxEqRel(
            weth.balanceOf(address(vault)) - floatBalance, assets / 2, maxAssetsDelta, "assets not withdrawn"
        );
        assertApproxEqRel(vault.totalInvested(), investAmount - (assets / 2), 0.001e18, "totalInvested not reduced");

        // withdraw the remaining assets
        hoax(keeper);
        vault.withdrawToVault(assets / 2);

        _floatCheck();

        uint256 dust = 100;
        assertLt(vault.totalDebt(), dust, "test_withdrawToVault getDebt error");
        assertLt(vault.totalCollateral(), dust, "test_withdrawToVault getCollateral error");
        assertApproxEqRel(
            weth.balanceOf(address(vault)) - floatBalance, assets, maxAssetsDelta, "test_withdrawToVault asset balance"
        );
        assertApproxEqRel(vault.totalInvested(), investAmount - assets, 0.001e18, "totalInvested not reduced");
    }

    // we decrease ltv in case of a loss, since the ltv goes higher than the target ltv in such a scenario
    function test_disinvest(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        uint256 minimumDust = amount.mulWadDown(0.01e18) + (amount - investAmount);

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after invest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after invest");

        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 eulerLtv = vaultHelper.getLtv(eulerAdapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);

        // disinvest to decrease the ltv on each protocol
        uint256 ltvDecrease = 0.1e18;

        uint256 aaveV3Allocation = vaultHelper.allocationPercent(aaveV3Adapter);
        uint256 eulerAllocation = vaultHelper.allocationPercent(eulerAdapter);
        uint256 compoundAllocation = vaultHelper.allocationPercent(compoundV3Adapter);

        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParams =
            _getDisInvestParams(aaveV3Ltv - ltvDecrease, eulerLtv - ltvDecrease, compoundLtv - ltvDecrease);

        uint256 assets = vault.totalAssets();
        uint256 lev = vaultHelper.getLeverage();
        uint256 ltv = vaultHelper.getLtv();

        hoax(keeper);
        vault.disinvest(repayWithdrawParams, "");

        _floatCheck();

        assertApproxEqRel(
            vaultHelper.getLtv(aaveV3Adapter), aaveV3Ltv - ltvDecrease, 0.0000001e18, "aavev3 ltv not decreased"
        );
        assertApproxEqRel(
            vaultHelper.getLtv(eulerAdapter), eulerLtv - ltvDecrease, 0.0000001e18, "euler ltv not decreased"
        );
        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter), compoundLtv - ltvDecrease, 0.0000001e18, "euler ltv not decreased"
        );
        assertApproxEqRel(vaultHelper.getLtv(), ltv - ltvDecrease, 0.01e18, "net ltv not decreased");

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after disinvest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after disinvest");
        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "disinvest must not change total assets");
        assertGe(lev - vaultHelper.getLeverage(), 0.4e18, "leverage not decreased after disinvest");

        // allocations must not change
        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter),
            aaveV3Allocation,
            0.001e18,
            "aavev3 allocation must not change"
        );
        assertApproxEqRel(
            vaultHelper.allocationPercent(eulerAdapter), eulerAllocation, 0.001e18, "euler allocation must not change"
        );
        assertApproxEqRel(
            vaultHelper.allocationPercent(compoundV3Adapter),
            compoundAllocation,
            0.001e18,
            "compound allocation must not change"
        );
    }

    // reallocate from aaveV3 to euler
    function test_reallocate_fromHigherLtvMarket_toLowerLtvMarket(uint256 amount) public {
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        uint256 aaveV3Allocation = 0.7e18;
        uint256 eulerAllocation = 0.3e18;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3Allocation, eulerAllocation, 0);

        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        uint256 aaveV3Assets = vaultHelper.getAssets(aaveV3Adapter);
        uint256 eulerAssets = vaultHelper.getAssets(eulerAdapter);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 eulerLtv = vaultHelper.getLtv(eulerAdapter);

        // reallocate 10% of the totalAssets from aavev3 to euler
        uint256 reallocationAmount = investAmount.mulWadDown(0.1e18); // in weth

        (
            scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation,
            scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation,
            uint256 delta
        ) = _getReallocationParamsWhenMarket1HasHigherLtv(reallocationAmount, aaveV3Assets, eulerLtv);

        // so after reallocation aaveV3 must have 60% and euler must have 40% funds respectively
        uint256 deltaWstEth = oracleLib.ethToWstEth(delta);
        hoax(keeper);
        vault.reallocate(repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, "", "", deltaWstEth, 0);

        _floatCheck();

        _reallocationChecksWhenMarket1HasHigherLtv(
            totalAssets,
            aaveV3Allocation,
            eulerAllocation,
            aaveV3Assets,
            eulerAssets,
            aaveV3Ltv,
            eulerLtv,
            reallocationAmount
        );
    }

    // reallocate from euler to aaveV3
    function test_reallocate_fromLowerLtvMarket_toHigherLtvMarket(uint256 amount) public {
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        uint256 aaveV3Allocation = 0.7e18;
        uint256 eulerAllocation = 0.3e18;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3Allocation, eulerAllocation, 0);

        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        uint256 aaveV3Assets = vaultHelper.getAssets(aaveV3Adapter);
        uint256 eulerAssets = vaultHelper.getAssets(eulerAdapter);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 eulerLtv = vaultHelper.getLtv(eulerAdapter);

        // reallocate 10% of the totalAssets from euler to aaveV3
        uint256 reallocationAmount = investAmount.mulWadDown(0.1e18); // in weth

        (
            scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation,
            scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation,
            uint256 delta
        ) = _getReallocationParamsWhenMarket1HasLowerLtv(reallocationAmount, eulerAssets, aaveV3Ltv);

        // so after reallocation aaveV3 must have 80% and euler must have 20% funds respectively
        uint256 deltaWstEth = oracleLib.ethToWstEth(delta);
        hoax(keeper);
        vault.reallocate(repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, "", "", deltaWstEth, 0);

        _floatCheck();

        _reallocationChecksWhenMarket1HasLowerLtv(
            totalAssets, aaveV3Assets, eulerAssets, aaveV3Ltv, eulerLtv, reallocationAmount
        );
    }

    // reallocating funds from euler to aaveV3 and compoundV3
    function test_reallocate_fromOneMarket_ToTwoMarkets(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        uint256 aaveV3Assets = vaultHelper.getAssets(aaveV3Adapter);
        uint256 eulerAssets = vaultHelper.getAssets(eulerAdapter);
        uint256 compoundAssets = vaultHelper.getAssets(compoundV3Adapter);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 eulerLtv = vaultHelper.getLtv(eulerAdapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);

        uint256 reallocationAmount = investAmount.mulWadDown(0.1e18); // in weth

        (
            scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation,
            scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation,
            uint256 delta
        ) = _getReallocationParamsFromOneMarketToTwoMarkets(reallocationAmount);

        uint256 deltaWstEth = oracleLib.ethToWstEth(delta);
        hoax(keeper);
        vault.reallocate(repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, "", "", deltaWstEth, 0);

        _reallocationChecksFromOneMarketToTwoMarkets(
            totalAssets, aaveV3Assets, eulerAssets, compoundAssets, aaveV3Ltv, eulerLtv, compoundLtv, reallocationAmount
        );
    }

    // reallocating funds from aveV3 and compoundV3 to euler
    function test_reallocate_fromTwoMarkets_ToOneMarket(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        uint256 aaveV3Assets = vaultHelper.getAssets(aaveV3Adapter);
        uint256 eulerAssets = vaultHelper.getAssets(eulerAdapter);
        uint256 compoundAssets = vaultHelper.getAssets(compoundV3Adapter);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 eulerLtv = vaultHelper.getLtv(eulerAdapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);

        uint256 reallocationAmount = investAmount.mulWadDown(0.1e18); // in weth

        (
            scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation,
            scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation,
            uint256 delta
        ) = _getReallocationParamsFromTwoMarketsToOneMarket(reallocationAmount);

        uint256 deltaWstEth = oracleLib.ethToWstEth(delta);
        hoax(keeper);
        vault.reallocate(repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, "", "", deltaWstEth, 0);

        _reallocationChecksFromTwoMarkets_TwoOneMarket(
            totalAssets, aaveV3Assets, eulerAssets, compoundAssets, aaveV3Ltv, eulerLtv, compoundLtv, reallocationAmount
        );
    }

    function test_invest_reinvestingProfits_performanceFees(uint256 amount) public {
        vault.setTreasury(treasury);
        amount = bound(amount, boundMinimum, 5000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        // note: simulating profits testing only for aave and compound and not for euler due to the shitty interest rates of euler after getting rekt
        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) = _getInvestParams(investAmount, 0.8e18, 0, 0.2e18);

        hoax(keeper);
        vault.investAndHarvest(investAmount, supplyBorrowParams, "");

        uint256 altv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);
        uint256 ltv = vaultHelper.getLtv();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        assertLt(vaultHelper.getLtv(), ltv, "ltv must decrease after simulated profits");
        assertLt(vaultHelper.getLtv(aaveV3Adapter), altv, "aavev3 ltv must decrease after simulated profits");

        assertLt(
            vaultHelper.getLtv(compoundV3Adapter), compoundLtv, "compound ltv must decrease after simulated profits"
        );

        uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, 0);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, 0);

        uint256 stEthRateTolerance = 0.999e18;
        uint256 aaveV3SupplyAmount = oracleLib.ethToWstEth(aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount = oracleLib.ethToWstEth(compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsAfterProfits = new scWETHv2.SupplyBorrowParam[](2);

        supplyBorrowParamsAfterProfits[0] = scWETHv2.SupplyBorrowParam({
            protocolId: aaveV3AdapterId,
            supplyAmount: aaveV3SupplyAmount,
            borrowAmount: aaveV3FlashLoanAmount
        });
        supplyBorrowParamsAfterProfits[1] = scWETHv2.SupplyBorrowParam({
            protocolId: compoundV3AdapterId,
            supplyAmount: compoundSupplyAmount,
            borrowAmount: compoundFlashLoanAmount
        });

        hoax(keeper);
        vault.investAndHarvest(0, supplyBorrowParamsAfterProfits, "");

        _floatCheck();

        assertApproxEqRel(altv, vaultHelper.getLtv(aaveV3Adapter), 0.0015e18, "aavev3 ltvs not reset after reinvest");

        assertApproxEqRel(
            compoundLtv, vaultHelper.getLtv(compoundV3Adapter), 0.0015e18, "compound ltvs not reset after reinvest"
        );

        assertApproxEqRel(ltv, vaultHelper.getLtv(), 0.005e18, "net ltv not reset after reinvest");

        uint256 balance = vault.convertToAssets(vault.balanceOf(treasury));
        uint256 profit = vault.totalProfit();
        assertApproxEqRel(balance, profit.mulWadDown(vault.performanceFee()), 0.015e18);
    }

    function test_approveEuler() public {
        vm.expectRevert(CallerNotKeeper.selector);
        vm.prank(alice);
        vault.approveEuler();

        hoax(keeper);
        vault.approveEuler();
        assertEq(ERC20(C.WSTETH).allowance(address(vault), C.EULER), type(uint256).max);
        assertEq(ERC20(C.WETH).allowance(address(vault), C.EULER), type(uint256).max);
    }

    function test_swapTokens() public {
        bytes memory swapData = hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000186a0000000000000000000000000000000000000000000000000000000000abe8b3f00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000006b175474e89094c44da98b954eedeac495271d0f869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000286c9ba65f6465ec08";
        address inToken = C.WETH;
        address outToken = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI
        uint256 amountIn = 100000;
        uint256 amountMinOut = 0;

        vm.deal(address(this), amountIn);
        vault.deposit{value: amountIn}(address(this));
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.swapTokens(swapData, inToken, outToken, amountIn, amountMinOut);

        hoax(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(TokenSwapFailed.selector, inToken, outToken)
        );
        vault.swapTokens(swapData, inToken, outToken, amountIn, amountMinOut);
    }

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    function _calcSupplyBorrowFlashLoanAmount(IAdapter adapter, uint256 amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vaultHelper.getDebt(adapter);
        uint256 collateral = vaultHelper.getCollateral(adapter);

        uint256 target = targetLtv[adapter].mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[adapter]);
    }

    function _calcRepayWithdrawFlashLoanAmount(IAdapter adapter, uint256 amount, uint256 ltv)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vaultHelper.getDebt(adapter);
        uint256 collateral = vaultHelper.getCollateral(adapter);

        uint256 target = ltv.mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (debt - target).divWadDown(C.ONE - ltv);
    }

    // market1 is the protocol we withdraw assets from
    // and market2 is the protocol we supply those assets to
    function _getReallocationParamsWhenMarket1HasHigherLtv(
        uint256 reallocationAmount,
        uint256 market1Assets,
        uint256 market2Ltv
    ) internal view returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256) {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        uint256 repayAmount = reallocationAmount.mulDivDown(vaultHelper.getDebt(aaveV3Adapter), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] =
            scWETHv2.RepayWithdrawParam(aaveV3AdapterId, repayAmount, oracleLib.ethToWstEth(withdrawAmount));

        // since the ltv of the second protocol euler is less than the first protocol aaveV3
        // we cannot supply the withdraw amount and borrow the repay Amount since that will increase the ltv of euler
        uint256 delta = (repayAmount - market2Ltv.mulWadDown(withdrawAmount)).divWadDown(1e18 - market2Ltv);
        uint256 market2SupplyAmount = withdrawAmount - delta;
        uint256 market2BorrowAmount = repayAmount - delta;

        supplyBorrowParamsReallocation[0] =
            scWETHv2.SupplyBorrowParam(eulerAdapterId, oracleLib.ethToWstEth(market2SupplyAmount), market2BorrowAmount);

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    function _getReallocationParamsWhenMarket1HasLowerLtv(
        uint256 reallocationAmount,
        uint256 market1Assets,
        uint256 market2Ltv
    ) internal view returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256) {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        uint256 repayAmount = reallocationAmount.mulDivDown(vaultHelper.getDebt(eulerAdapter), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] =
            scWETHv2.RepayWithdrawParam(eulerAdapterId, repayAmount, oracleLib.ethToWstEth(withdrawAmount));

        uint256 market2SupplyAmount = repayAmount.divWadDown(market2Ltv);
        uint256 market2BorrowAmount = repayAmount;

        uint256 delta = withdrawAmount - market2SupplyAmount;

        supplyBorrowParamsReallocation[0] =
            scWETHv2.SupplyBorrowParam(aaveV3AdapterId, oracleLib.ethToWstEth(market2SupplyAmount), market2BorrowAmount);

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    function _getReallocationParamsFromOneMarketToTwoMarkets(uint256 reallocationAmount)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256)
    {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](2);

        uint256 repayAmount =
            reallocationAmount.mulDivDown(vaultHelper.getDebt(eulerAdapter), vaultHelper.getAssets(eulerAdapter));
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] =
            scWETHv2.RepayWithdrawParam(eulerAdapterId, repayAmount, oracleLib.ethToWstEth(withdrawAmount));

        // supply 50% of the reallocationAmount to aaveV3 and 50% to compoundV3
        // we are using the below style of calculating since aaveV3 and compoundV3 both have higher ltv than euler
        uint256 aaveV3SupplyAmount = (repayAmount / 2).divWadDown(vaultHelper.getLtv(aaveV3Adapter));
        uint256 aaveV3BorrowAmount = (repayAmount / 2);

        uint256 compoundSupplyAmount = (repayAmount / 2).divWadDown(vaultHelper.getLtv(compoundV3Adapter));
        uint256 compoundBorrowAmount = (repayAmount / 2);

        uint256 delta = withdrawAmount - (aaveV3SupplyAmount + compoundSupplyAmount);

        supplyBorrowParamsReallocation[0] = scWETHv2.SupplyBorrowParam({
            protocolId: aaveV3AdapterId,
            supplyAmount: oracleLib.ethToWstEth(aaveV3SupplyAmount),
            borrowAmount: aaveV3BorrowAmount
        });

        supplyBorrowParamsReallocation[1] = scWETHv2.SupplyBorrowParam({
            protocolId: compoundV3AdapterId,
            supplyAmount: oracleLib.ethToWstEth(compoundSupplyAmount),
            borrowAmount: compoundBorrowAmount
        });

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    function _getReallocationParamsFromTwoMarketsToOneMarket(uint256 reallocationAmount)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256)
    {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](2);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        // we will withdraw 50% of the reallocation amount from aaveV3 and the other 50% from compoundV3
        uint256 reallocationAmountPerMarket = reallocationAmount / 2;

        uint256 repayAmountAaveV3 = reallocationAmountPerMarket.mulDivDown(
            vaultHelper.getDebt(aaveV3Adapter), vaultHelper.getAssets(aaveV3Adapter)
        );
        uint256 withdrawAmountAaveV3 = reallocationAmountPerMarket + repayAmountAaveV3;

        uint256 repayAmountCompoundV3 = reallocationAmountPerMarket.mulDivDown(
            vaultHelper.getDebt(compoundV3Adapter), vaultHelper.getAssets(compoundV3Adapter)
        );
        uint256 withdrawAmountCompoundV3 = reallocationAmountPerMarket + repayAmountCompoundV3;

        repayWithdrawParamsReallocation[0] =
            scWETHv2.RepayWithdrawParam(aaveV3AdapterId, repayAmountAaveV3, oracleLib.ethToWstEth(withdrawAmountAaveV3));

        repayWithdrawParamsReallocation[1] = scWETHv2.RepayWithdrawParam(
            compoundV3AdapterId, repayAmountCompoundV3, oracleLib.ethToWstEth(withdrawAmountCompoundV3)
        );

        uint256 repayAmount = repayAmountAaveV3 + repayAmountCompoundV3;
        uint256 withdrawAmount = withdrawAmountAaveV3 + withdrawAmountCompoundV3;
        uint256 eulerLtv = vaultHelper.getLtv(eulerAdapter);

        uint256 delta = (repayAmount - eulerLtv.mulWadDown(withdrawAmount)).divWadDown(1e18 - eulerLtv);
        uint256 eulerSupplyAmount = withdrawAmount - delta;
        uint256 eulerBorrowAmount = repayAmount - delta;

        supplyBorrowParamsReallocation[0] =
            scWETHv2.SupplyBorrowParam(eulerAdapterId, oracleLib.ethToWstEth(eulerSupplyAmount), eulerBorrowAmount);

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken
    function _getInvestParams(
        uint256 amount,
        uint256 aaveV3Allocation,
        uint256 eulerAllocation,
        uint256 compoundAllocation
    ) internal view returns (scWETHv2.SupplyBorrowParam[] memory, uint256, uint256) {
        uint256 stEthRateTolerance = 0.999e18;
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams = new scWETHv2.SupplyBorrowParam[](3);

        // supply 70% to aaveV3 and 30% to Euler
        uint256 aaveV3Amount = amount.mulWadDown(aaveV3Allocation);
        uint256 eulerAmount = amount.mulWadDown(eulerAllocation);
        uint256 compoundAmount = amount.mulWadDown(compoundAllocation);

        uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, aaveV3Amount);
        uint256 eulerFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(eulerAdapter, eulerAmount);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);

        uint256 aaveV3SupplyAmount =
            oracleLib.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 eulerSupplyAmount =
            oracleLib.ethToWstEth(eulerAmount + eulerFlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            oracleLib.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        supplyBorrowParams[0] = scWETHv2.SupplyBorrowParam({
            protocolId: aaveV3AdapterId,
            supplyAmount: aaveV3SupplyAmount,
            borrowAmount: aaveV3FlashLoanAmount
        });
        supplyBorrowParams[1] = scWETHv2.SupplyBorrowParam({
            protocolId: eulerAdapterId,
            supplyAmount: eulerSupplyAmount,
            borrowAmount: eulerFlashLoanAmount
        });
        supplyBorrowParams[2] = scWETHv2.SupplyBorrowParam({
            protocolId: compoundV3AdapterId,
            supplyAmount: compoundSupplyAmount,
            borrowAmount: compoundFlashLoanAmount
        });

        uint256 totalSupplyAmount = aaveV3SupplyAmount + eulerSupplyAmount + compoundSupplyAmount;
        uint256 totalDebtTaken = aaveV3FlashLoanAmount + eulerFlashLoanAmount + compoundFlashLoanAmount;

        return (supplyBorrowParams, totalSupplyAmount, totalDebtTaken);
    }

    /// @return : repayWithdrawParams
    function _getDisInvestParams(uint256 newAaveV3Ltv, uint256 newEulerLtv, uint256 newCompoundLtv)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory)
    {
        uint256 aaveV3FlashLoanAmount = _calcRepayWithdrawFlashLoanAmount(aaveV3Adapter, 0, newAaveV3Ltv);
        uint256 eulerFlashLoanAmount = _calcRepayWithdrawFlashLoanAmount(eulerAdapter, 0, newEulerLtv);
        uint256 compoundFlashLoanAmount = _calcRepayWithdrawFlashLoanAmount(compoundV3Adapter, 0, newCompoundLtv);

        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParams = new scWETHv2.RepayWithdrawParam[](3);

        repayWithdrawParams[0] = scWETHv2.RepayWithdrawParam(
            aaveV3AdapterId, aaveV3FlashLoanAmount, oracleLib.ethToWstEth(aaveV3FlashLoanAmount)
        );

        repayWithdrawParams[1] = scWETHv2.RepayWithdrawParam(
            eulerAdapterId, eulerFlashLoanAmount, oracleLib.ethToWstEth(eulerFlashLoanAmount)
        );

        repayWithdrawParams[2] = scWETHv2.RepayWithdrawParam(
            compoundV3AdapterId, compoundFlashLoanAmount, oracleLib.ethToWstEth(compoundFlashLoanAmount)
        );

        return repayWithdrawParams;
    }

    function _depositChecks(uint256 amount, uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18, "convertToAssets decimal assertion failed");
        assertEq(vault.totalAssets(), amount, "totalAssets assertion failed");
        assertEq(vault.balanceOf(address(this)), amount, "balanceOf assertion failed");
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount, "convertToAssets assertion failed");
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount, "weth balance assertion failed");
    }

    function _redeemChecks(uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(weth.balanceOf(address(this)), preDepositBal);
    }

    function _investChecks(uint256 amount, uint256 totalSupplyAmount, uint256 totalDebtTaken) internal {
        uint256 totalCollateral = vault.totalCollateral();
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, amount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), amount, "totalInvested not updated");
        assertApproxEqRel(totalCollateral, totalSupplyAmount, 0.0001e18, "totalCollateral not equal totalSupplyAmount");
        assertApproxEqRel(totalDebt, totalDebtTaken, 100, "totalDebt not equal totalDebtTaken");

        uint256 aaveV3Deposited = vaultHelper.getCollateral(aaveV3Adapter) - vaultHelper.getDebt(aaveV3Adapter);
        uint256 eulerDeposited = vaultHelper.getCollateral(eulerAdapter) - vaultHelper.getDebt(eulerAdapter);
        uint256 compoundDeposited =
            vaultHelper.getCollateral(compoundV3Adapter) - vaultHelper.getDebt(compoundV3Adapter);

        assertApproxEqRel(
            aaveV3Deposited, amount.mulWadDown(aaveV3AllocationPercent), 0.005e18, "aaveV3 allocation not correct"
        );
        assertApproxEqRel(
            eulerDeposited, amount.mulWadDown(eulerAllocationPercent), 0.005e18, "euler allocation not correct"
        );
        assertApproxEqRel(
            compoundDeposited, amount.mulWadDown(compoundAllocationPercent), 0.005e18, "compound allocation not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter),
            aaveV3AllocationPercent,
            0.005e18,
            "aaveV3 allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(eulerAdapter),
            eulerAllocationPercent,
            0.005e18,
            "euler allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(compoundV3Adapter),
            compoundAllocationPercent,
            0.005e18,
            "compound allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(aaveV3Adapter), targetLtv[aaveV3Adapter], 0.005e18, "aaveV3 ltv not correct"
        );
        assertApproxEqRel(vaultHelper.getLtv(eulerAdapter), targetLtv[eulerAdapter], 0.005e18, "euler ltv not correct");

        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter), targetLtv[compoundV3Adapter], 0.005e18, "compound ltv not correct"
        );
    }

    function _reallocationChecksWhenMarket1HasHigherLtv(
        uint256 totalAssets,
        uint256 inititalAaveV3Allocation,
        uint256 initialEulerAllocation,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 reallocationAmount
    ) internal {
        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter),
            inititalAaveV3Allocation - 0.1e18,
            0.005e18,
            "aavev3 allocation error"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(eulerAdapter),
            initialEulerAllocation + 0.1e18,
            0.005e18,
            "euler allocation error"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(aaveV3Adapter),
            inititalAaveV3Assets - reallocationAmount,
            0.001e18,
            "aavev3 assets not decreased"
        );

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(eulerAdapter),
            initialEulerAssets + reallocationAmount,
            0.001e18,
            "euler assets not increased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(vaultHelper.getLtv(aaveV3Adapter), initialAaveV3Ltv, 0.001e18, "aavev3 ltv must not change");

        assertApproxEqRel(vaultHelper.getLtv(eulerAdapter), initialEulerLtv, 0.001e18, "euler ltv must not change");
    }

    function _reallocationChecksWhenMarket1HasLowerLtv(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 reallocationAmount
    ) internal {
        // note: after reallocating from a lower ltv protocol to a higher ltv protocol
        // there is some float remaining in the contract due to the difference in ltv
        uint256 float = weth.balanceOf(address(vault));

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(aaveV3Adapter) + float - minimumFloatAmount,
            inititalAaveV3Assets + reallocationAmount,
            0.001e18,
            "aavev3 assets not increased"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(eulerAdapter),
            initialEulerAssets - reallocationAmount,
            0.001e18,
            "euler assets not decreased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(vaultHelper.getLtv(aaveV3Adapter), initialAaveV3Ltv, 0.001e18, "aavev3 ltv must not change");

        assertApproxEqRel(vaultHelper.getLtv(eulerAdapter), initialEulerLtv, 0.001e18, "euler ltv must not change");
    }

    function _reallocationChecksFromOneMarketToTwoMarkets(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialCompoundAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 initialCompoundLtv,
        uint256 reallocationAmount
    ) internal {
        // note: after reallocating from a lower ltv protocol to a higher ltv market
        // there is some float remaining in the contract due to the difference in ltv
        uint256 float = weth.balanceOf(address(vault));

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(aaveV3Adapter) + vaultHelper.getAssets(compoundV3Adapter) + float - minimumFloatAmount,
            inititalAaveV3Assets + initialCompoundAssets + reallocationAmount,
            0.001e18,
            "aavev3 & compound assets not increased"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(eulerAdapter),
            initialEulerAssets - reallocationAmount,
            0.001e18,
            "euler assets not decreased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(vaultHelper.getLtv(aaveV3Adapter), initialAaveV3Ltv, 0.001e18, "aavev3 ltv must not change");

        assertApproxEqRel(vaultHelper.getLtv(eulerAdapter), initialEulerLtv, 0.001e18, "euler ltv must not change");

        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter), initialCompoundLtv, 0.001e18, "compound ltv must not change"
        );
    }

    function _reallocationChecksFromTwoMarkets_TwoOneMarket(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialCompoundAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 initialCompoundLtv,
        uint256 reallocationAmount
    ) internal {
        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter) + vaultHelper.allocationPercent(compoundV3Adapter),
            aaveV3AllocationPercent + compoundAllocationPercent - 0.1e18,
            0.005e18,
            "aavev3 & compound allocation error"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(eulerAdapter),
            eulerAllocationPercent + 0.1e18,
            0.005e18,
            "euler allocation error"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(aaveV3Adapter) + vaultHelper.getAssets(compoundV3Adapter),
            inititalAaveV3Assets + initialCompoundAssets - reallocationAmount,
            0.001e18,
            "aavev3 & compound assets not decreased"
        );

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(eulerAdapter),
            initialEulerAssets + reallocationAmount,
            0.001e18,
            "euler assets not increased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(vaultHelper.getLtv(aaveV3Adapter), initialAaveV3Ltv, 0.001e18, "aavev3 ltv must not change");

        assertApproxEqRel(vaultHelper.getLtv(eulerAdapter), initialEulerLtv, 0.001e18, "euler ltv must not change");

        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter), initialCompoundLtv, 0.001e18, "compound ltv must not change"
        );
    }

    function _floatCheck() internal {
        assertGe(weth.balanceOf(address(vault)), minimumFloatAmount, "float not maintained");
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        deal(address(weth), user, amount);
        vm.startPrank(user);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _deployOracleLib() internal returns (OracleLib) {
        return new OracleLib(AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED), C.WSTETH, C.WETH, admin);
    }

    // function _deployLendingManagerContract() internal returns (LendingMarketManager) {
    //     LendingMarketManager.AaveV3 memory aaveV3 = LendingMarketManager.AaveV3({
    //         pool: C.AAVE_POOL,
    //         aWstEth: C.AAVE_AWSTETH_TOKEN,
    //         varDWeth: C.AAVAAVE_VAR_DEBT_WETH_TOKEN
    //     });

    //     LendingMarketManager.Euler memory euler = LendingMarketManager.Euler({
    //         protocol: C.EULER,
    //         markets: C.EULER_MARKETS,
    //         eWstEth: C.EULER_ETOKEN_WSTETH,
    //         dWeth: C.EULER_DTOKEN_WETH
    //     });

    //     LendingMarketManager.Compound memory compound = LendingMarketManager.Compound({comet: C.COMPOUND_V3_COMET_WETH});

    //     return new LendingMarketManager(C.STETH, C.WSTETH, C.WETH, aaveV3, euler, compound);
    // }

    function _createDefaultWethv2VaultConstructorParams(OracleLib _oracleLib)
        internal
        view
        returns (scWETHv2.ConstructorParams memory)
    {
        return scWETHv2.ConstructorParams({
            admin: admin,
            keeper: keeper,
            slippageTolerance: slippageTolerance,
            stEth: C.STETH,
            wstEth: C.WSTETH,
            weth: C.WETH,
            curvePool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            balancerVault: IVault(C.BALANCER_VAULT),
            oracleLib: _oracleLib
        });
    }

    function _simulate_stEthStakingInterest(uint256 timePeriod, uint256 stEthStakingInterest) internal {
        // fast forward time to simulate supply and borrow interests
        vm.warp(block.timestamp + timePeriod);
        uint256 prevBalance = read_storage_uint(address(stEth), keccak256(abi.encodePacked("lido.Lido.beaconBalance")));
        vm.store(
            address(stEth),
            keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
            bytes32(prevBalance.mulWadDown(stEthStakingInterest))
        );
    }

    function read_storage_uint(address addr, bytes32 key) internal view returns (uint256) {
        return abi.decode(abi.encode(vm.load(addr, key)), (uint256));
    }

    receive() external payable {}
}
