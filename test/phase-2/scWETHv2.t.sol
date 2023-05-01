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
import {LendingMarketManager} from "../../src/phase-2/LendingMarketManager.sol";
import {MockLendingMarketManager} from "../mock/MockLendingMarketManager.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../../src/interfaces/balancer/IVault.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../../src/sc4626.sol";
import "../../src/errors/scErrors.sol";

contract scWETHv2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1e10; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETHv2 vault;
    uint256 initAmount = 100e18;

    uint256 slippageTolerance = 0.99e18;
    uint256 maxLtv;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    AggregatorV3Interface public stEThToEthPriceFeed;

    mapping(LendingMarketManager.LendingMarketType => uint256) targetLtv;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16784444);

        scWETHv2.ConstructorParams memory params = _createDefaultWethv2VaultConstructorParams();

        vault = new scWETHv2(params);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();
        stEThToEthPriceFeed = vault.stEThToEthPriceFeed();

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        targetLtv[LendingMarketManager.LendingMarketType.AAVE_V3] = 0.7e18;
        targetLtv[LendingMarketManager.LendingMarketType.EULER] = 0.5e18;
    }

    function test_constructor() public {
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true, "admin role not set");
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), keeper), true, "keeper role not set");
        assertEq(address(vault.weth()), C.WETH);
        assertEq(address(vault.stEth()), C.STETH);
        assertEq(address(vault.wstETH()), C.WSTETH);
        assertEq(address(vault.curvePool()), C.CURVE_ETH_STETH_POOL);
        assertEq(address(vault.balancerVault()), C.BALANCER_VAULT);
        assertEq(address(vault.stEThToEthPriceFeed()), C.CHAINLINK_STETH_ETH_PRICE_FEED);
        assertEq(vault.slippageTolerance(), slippageTolerance);
    }

    function test_deposit_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        vault.deposit(amount, address(this));

        _depositChecks(amount, preDepositBal);

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        _redeemChecks(preDepositBal);
    }

    function test_invest(uint256 amount) public {
        amount = bound(amount, boundMinimum, 20000 ether);
        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 aaveV3AllocationPercent = 0.7e18;
        uint256 eulerAllocationPercent = 0.3e18;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams, uint256 totalSupplyAmount, uint256 totalDebtTaken) =
            _getInvestParams(amount, aaveV3AllocationPercent, eulerAllocationPercent);

        // deposit into strategy
        hoax(keeper);
        vault.invest(amount, supplyBorrowParams);

        _investChecks(
            amount, _wstEthToEth(totalSupplyAmount), totalDebtTaken, aaveV3AllocationPercent, eulerAllocationPercent
        );
    }

    function test_deposit_invest_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 20000 ether);
        uint256 shares = _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) = _getInvestParams(amount, 0.7e18, 0.3e18);

        // deposit into strategy
        hoax(keeper);
        vault.invest(amount, supplyBorrowParams);

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
        amount = bound(amount, boundMinimum, 20000 ether);
        uint256 maxAssetsDelta = 0.01e18;
        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) = _getInvestParams(amount, 0.7e18, 0.3e18);

        // deposit into strategy
        hoax(keeper);
        vault.invest(amount, supplyBorrowParams);

        uint256 assets = vault.totalAssets();

        assertEq(weth.balanceOf(address(vault)), 0);

        uint256 ltv = vault.getLtv();
        uint256 lev = vault.getLeverage();

        hoax(keeper);
        vault.withdrawToVault(assets / 2);

        // net ltv and leverage must not change after withdraw
        assertApproxEqRel(vault.getLtv(), ltv, 0.001e18, "ltv changed after withdraw");
        assertApproxEqRel(vault.getLeverage(), lev, 0.001e18, "leverage changed after withdraw");
        assertApproxEqRel(weth.balanceOf(address(vault)), assets / 2, maxAssetsDelta, "assets not withdrawn");

        // withdraw the remaining assets
        hoax(keeper);
        vault.withdrawToVault(assets / 2);

        uint256 dust = 100;
        assertLt(vault.totalDebt(), dust, "test_withdrawToVault getDebt error");
        assertLt(vault.totalCollateral(), dust, "test_withdrawToVault getCollateral error");
        assertApproxEqRel(weth.balanceOf(address(vault)), assets, maxAssetsDelta, "test_withdrawToVault asset balance");
    }

    // we decrease ltv in case of a loss, since the ltv goes higher than the target ltv in such a scenario
    function test_disinvest(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        _depositToVault(address(this), amount);

        uint256 minimumDust = amount.mulWadDown(0.01e18);

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) = _getInvestParams(amount, 0.7e18, 0.3e18);

        hoax(keeper);
        vault.invest(amount, supplyBorrowParams);

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after invest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after invest");

        uint256 aaveV3Ltv = vault.getLtv(LendingMarketManager.LendingMarketType.AAVE_V3);
        uint256 eulerLtv = vault.getLtv(LendingMarketManager.LendingMarketType.EULER);

        // disinvest to decrease the ltv on each protocol
        uint256 ltvDecrease = 0.1e18;
        uint256 newAaveV3Ltv = aaveV3Ltv - ltvDecrease;
        uint256 newEulerLtv = eulerLtv - ltvDecrease;
        uint256 aaveV3Allocation = vault.allocationPercent(LendingMarketManager.LendingMarketType.AAVE_V3);
        uint256 eulerAllocation = vault.allocationPercent(LendingMarketManager.LendingMarketType.EULER);

        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParams = _getDisInvestParams(newAaveV3Ltv, newEulerLtv);

        uint256 assets = vault.totalAssets();
        uint256 lev = vault.getLeverage();
        uint256 ltv = vault.getLtv();

        hoax(keeper);
        vault.disinvest(repayWithdrawParams);

        assertApproxEqRel(
            vault.getLtv(LendingMarketManager.LendingMarketType.AAVE_V3),
            newAaveV3Ltv,
            0.0000001e18,
            "aavev3 ltv not decreased"
        );
        assertApproxEqRel(
            vault.getLtv(LendingMarketManager.LendingMarketType.EULER),
            newEulerLtv,
            0.0000001e18,
            "euler ltv not decreased"
        );
        assertApproxEqRel(vault.getLtv(), ltv - ltvDecrease, 0.01e18, "net ltv not decreased");

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after disinvest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after disinvest");
        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "disinvest must not change total assets");
        assertGe(lev - vault.getLeverage(), 0.4e18, "leverage not decreased after disinvest");

        // allocations must not change
        assertApproxEqRel(
            vault.allocationPercent(LendingMarketManager.LendingMarketType.AAVE_V3),
            aaveV3Allocation,
            0.001e18,
            "aavev3 allocation must not change"
        );
        assertApproxEqRel(
            vault.allocationPercent(LendingMarketManager.LendingMarketType.EULER),
            eulerAllocation,
            0.001e18,
            "euler allocation must not change"
        );
    }

    function test_reallocate(uint256 amount) public {
        // uint256 amount = 10 ether;
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);

        uint256 aaveV3Allocation = 0.7e18;
        uint256 eulerAllocation = 0.3e18;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(amount, aaveV3Allocation, eulerAllocation);

        hoax(keeper);
        vault.invest(amount, supplyBorrowParams);

        uint256 aaveV3Assets = vault.getAssets(LendingMarketManager.LendingMarketType.AAVE_V3);
        uint256 eulerAssets = vault.getAssets(LendingMarketManager.LendingMarketType.EULER);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vault.getLtv(LendingMarketManager.LendingMarketType.AAVE_V3);
        uint256 eulerLtv = vault.getLtv(LendingMarketManager.LendingMarketType.EULER);

        // reallocate 10% of the totalAssets from aavev3 to euler
        uint256 reallocationAmount = amount.mulWadDown(0.1e18); // in weth

        (
            scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation,
            scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation,
            uint256 delta
        ) = _getReallocationParamsWhenSupplyMarketHasLowerLtvThanWithdrawMarket(
            reallocationAmount, aaveV3Assets, eulerLtv
        );

        // so after reallocation aaveV3 must have 60% and euler must have 40% funds respectively
        uint256 deltaWstEth = _ethToWstEth(delta);
        hoax(keeper);
        vault.reallocate(repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, deltaWstEth);

        _reallocationChecks(
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

    function test_invest_reinvestingProfits() public {}

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    function _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.LendingMarketType market, uint256 amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(market);
        uint256 collateral = vault.getCollateral(market);

        uint256 target = targetLtv[market].mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[market]);
    }

    function _calcRepayWithdrawFlashLoanAmount(
        LendingMarketManager.LendingMarketType market,
        uint256 amount,
        uint256 ltv
    ) internal view returns (uint256 flashLoanAmount) {
        uint256 debt = vault.getDebt(market);
        uint256 collateral = vault.getCollateral(market);

        uint256 target = ltv.mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (debt - target).divWadDown(C.ONE - ltv);
    }

    // market1 is the market we withdraw assets from
    // and market2 is the market we supply those assets to
    function _getReallocationParamsWhenSupplyMarketHasLowerLtvThanWithdrawMarket(
        uint256 reallocationAmount,
        uint256 market1Assets,
        uint256 market2Ltv
    ) internal view returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256) {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        uint256 repayAmount =
            reallocationAmount.mulDivDown(vault.getDebt(LendingMarketManager.LendingMarketType.AAVE_V3), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.LendingMarketType.AAVE_V3, repayAmount, _ethToWstEth(withdrawAmount)
        );

        // since the ltv of the second market euler is less than the first market aaveV3
        // we cannot supply the withdraw amount and borrow the repay Amount since that will increase the ltv of euler
        uint256 delta = (repayAmount - market2Ltv.mulWadDown(withdrawAmount)).divWadDown(1e18 - market2Ltv);
        console.log("Delta", delta);
        uint256 market2SupplyAmount = _ethToWstEth(withdrawAmount - delta);
        uint256 market2BorrowAmount = repayAmount - delta;

        supplyBorrowParamsReallocation[0] = scWETHv2.SupplyBorrowParam(
            LendingMarketManager.LendingMarketType.EULER, market2SupplyAmount, market2BorrowAmount
        );

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken
    function _getInvestParams(uint256 amount, uint256 aaveV3AllocationPercent, uint256 eulerAllocationPercent)
        internal
        view
        returns (scWETHv2.SupplyBorrowParam[] memory, uint256, uint256)
    {
        uint256 stEthRateTolerance = 0.999e18;
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams = new scWETHv2.SupplyBorrowParam[](2);

        // supply 70% to aaveV3 and 30% to Euler
        uint256 aaveV3Amount = amount.mulWadDown(aaveV3AllocationPercent);
        uint256 eulerAmount = amount.mulWadDown(eulerAllocationPercent);

        uint256 aaveV3FlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.LendingMarketType.AAVE_V3, aaveV3Amount);
        uint256 eulerFlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.LendingMarketType.EULER, eulerAmount);

        uint256 aaveV3SupplyAmount = _ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 eulerSupplyAmount = _ethToWstEth(eulerAmount + eulerFlashLoanAmount).mulWadDown(stEthRateTolerance);

        supplyBorrowParams[0] = scWETHv2.SupplyBorrowParam({
            market: LendingMarketManager.LendingMarketType.AAVE_V3,
            supplyAmount: aaveV3SupplyAmount,
            borrowAmount: aaveV3FlashLoanAmount
        });
        supplyBorrowParams[1] = scWETHv2.SupplyBorrowParam({
            market: LendingMarketManager.LendingMarketType.EULER,
            supplyAmount: eulerSupplyAmount,
            borrowAmount: eulerFlashLoanAmount
        });

        uint256 totalSupplyAmount = aaveV3SupplyAmount + eulerSupplyAmount;
        uint256 totalDebtTaken = aaveV3FlashLoanAmount + eulerFlashLoanAmount;

        return (supplyBorrowParams, totalSupplyAmount, totalDebtTaken);
    }

    /// @return : repayWithdrawParams
    function _getDisInvestParams(uint256 newAaveV3Ltv, uint256 newEulerLtv)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory)
    {
        uint256 aaveV3FlashLoanAmount =
            _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.LendingMarketType.AAVE_V3, 0, newAaveV3Ltv);
        uint256 eulerFlashLoanAmount =
            _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.LendingMarketType.EULER, 0, newEulerLtv);

        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParams = new scWETHv2.RepayWithdrawParam[](2);

        repayWithdrawParams[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.LendingMarketType.AAVE_V3, aaveV3FlashLoanAmount, _ethToWstEth(aaveV3FlashLoanAmount)
        );

        repayWithdrawParams[1] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.LendingMarketType.EULER, eulerFlashLoanAmount, _ethToWstEth(eulerFlashLoanAmount)
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

    function _investChecks(
        uint256 amount,
        uint256 totalSupplyAmount,
        uint256 totalDebtTaken,
        uint256 aaveV3AllocationPercent,
        uint256 eulerAllocationPercent
    ) internal {
        uint256 totalCollateral = vault.totalCollateral();
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, amount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), amount, "totalInvested not updated");
        assertApproxEqRel(totalCollateral, totalSupplyAmount, 0.0001e18, "totalCollateral not equal totalSupplyAmount");
        assertApproxEqRel(totalDebt, totalDebtTaken, 100, "totalDebt not equal totalDebtTaken");

        uint256 aaveV3Deposited = vault.getCollateral(LendingMarketManager.LendingMarketType.AAVE_V3)
            - vault.getDebt(LendingMarketManager.LendingMarketType.AAVE_V3);
        uint256 eulerDeposited = vault.getCollateral(LendingMarketManager.LendingMarketType.EULER)
            - vault.getDebt(LendingMarketManager.LendingMarketType.EULER);

        assertApproxEqRel(
            aaveV3Deposited, amount.mulWadDown(aaveV3AllocationPercent), 0.005e18, "aaveV3 allocation not correct"
        );
        assertApproxEqRel(
            eulerDeposited, amount.mulWadDown(eulerAllocationPercent), 0.005e18, "euler allocation not correct"
        );

        assertApproxEqRel(
            vault.allocationPercent(LendingMarketManager.LendingMarketType.AAVE_V3),
            aaveV3AllocationPercent,
            0.005e18,
            "aaveV3 allocationPercent not correct"
        );

        assertApproxEqRel(
            vault.allocationPercent(LendingMarketManager.LendingMarketType.EULER),
            eulerAllocationPercent,
            0.005e18,
            "euler allocationPercent not correct"
        );

        assertApproxEqRel(
            vault.getLtv(LendingMarketManager.LendingMarketType.AAVE_V3),
            targetLtv[LendingMarketManager.LendingMarketType.AAVE_V3],
            0.005e18,
            "aaveV3 ltv not correct"
        );
        assertApproxEqRel(
            vault.getLtv(LendingMarketManager.LendingMarketType.EULER),
            targetLtv[LendingMarketManager.LendingMarketType.EULER],
            0.005e18,
            "euler ltv not correct"
        );
    }

    function _reallocationChecks(
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
            vault.allocationPercent(LendingMarketManager.LendingMarketType.AAVE_V3),
            inititalAaveV3Allocation - 0.1e18,
            0.005e18,
            "aavev3 allocation not decreased"
        );

        assertApproxEqRel(
            vault.allocationPercent(LendingMarketManager.LendingMarketType.EULER),
            initialEulerAllocation + 0.1e18,
            0.005e18,
            "euler allocation not increased"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vault.getAssets(LendingMarketManager.LendingMarketType.AAVE_V3),
            inititalAaveV3Assets - reallocationAmount,
            0.001e18,
            "aavev3 assets not decreased"
        );

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vault.getAssets(LendingMarketManager.LendingMarketType.EULER),
            initialEulerAssets + reallocationAmount,
            0.001e18,
            "euler assets not increased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(
            vault.getLtv(LendingMarketManager.LendingMarketType.AAVE_V3),
            initialAaveV3Ltv,
            0.001e18,
            "aavev3 ltv must not change"
        );

        assertApproxEqRel(
            vault.getLtv(LendingMarketManager.LendingMarketType.EULER),
            initialEulerLtv,
            0.001e18,
            "euler ltv must not change"
        );
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        deal(address(weth), user, amount);
        vm.startPrank(user);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _createDefaultWethv2VaultConstructorParams() internal view returns (scWETHv2.ConstructorParams memory) {
        return scWETHv2.ConstructorParams({
            admin: admin,
            keeper: keeper,
            slippageTolerance: slippageTolerance,
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: WETH(payable(C.WETH)),
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });
    }

    function _ethToWstEth(uint256 ethAmount) internal view returns (uint256 wstEthAmount) {
        if (ethAmount > 0) {
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

            // eth to stEth
            uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

            // stEth to wstEth
            wstEthAmount = wstEth.getWstETHByStETH(stEthAmount);
        }
    }

    function _stEthToEth(uint256 stEthAmount) internal view returns (uint256 ethAmount) {
        if (stEthAmount > 0) {
            // stEth to eth
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();
            ethAmount = stEthAmount.mulWadDown(uint256(price));
        }
    }

    function _wstEthToEth(uint256 wstEthAmount) internal view returns (uint256 ethAmount) {
        // wstETh to stEth using exchangeRate
        uint256 stEthAmount = wstEth.getStETHByWstETH(wstEthAmount);
        ethAmount = _stEthToEth(stEthAmount);
    }
}
