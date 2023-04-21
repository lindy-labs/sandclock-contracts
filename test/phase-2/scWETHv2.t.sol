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

    // function test_deposit_redeem(uint256 amount) public {
    //     amount = bound(amount, boundMinimum, 1e27);
    //     vm.deal(address(this), amount);
    //     weth.deposit{value: amount}();
    //     weth.approve(address(vault), amount);

    //     uint256 preDepositBal = weth.balanceOf(address(this));

    //     vault.deposit(amount, address(this));

    //     _depositChecks(amount, preDepositBal);

    //     vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

    //     _redeemChecks(preDepositBal);
    // }

    function test_rebalance_depositIntoStrategy() public {
        uint256 amount = 10 ether;
        _depositToVault(address(this), amount);

        _depositChecks(amount, amount);

        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParams;
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams = new scWETHv2.SupplyBorrowParam[](2);

        // supply 70% to aaveV3 and 30% to Euler
        uint256 aaveV3Amount = amount.mulWadDown(0.7e18);
        uint256 eulerAmount = amount.mulWadDown(0.3e18);

        uint256 aaveV3FlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.LendingMarketType.AAVE_V3, aaveV3Amount);
        uint256 eulerFlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.LendingMarketType.EULER, eulerAmount);

        supplyBorrowParams[0] = scWETHv2.SupplyBorrowParam({
            market: LendingMarketManager.LendingMarketType.AAVE_V3,
            supplyAmount: aaveV3Amount + aaveV3FlashLoanAmount,
            borrowAmount: aaveV3FlashLoanAmount
        });

        supplyBorrowParams[1] = scWETHv2.SupplyBorrowParam({
            market: LendingMarketManager.LendingMarketType.EULER,
            supplyAmount: eulerAmount + eulerFlashLoanAmount,
            borrowAmount: eulerFlashLoanAmount
        });

        uint256 totalFlashLoanAmount = aaveV3FlashLoanAmount + eulerFlashLoanAmount;

        scWETHv2.RebalanceParams memory rebalanceParams = scWETHv2.RebalanceParams({
            repayWithdrawParams: repayWithdrawParams,
            supplyBorrowParams: supplyBorrowParams,
            doWstEthToWethSwap: false,
            doWethToWstEthSwap: true,
            wethSwapAmount: totalFlashLoanAmount + amount
        });

        // deposit into strategy
        hoax(keeper);
        vault.rebalance(totalFlashLoanAmount, rebalanceParams);
    }

    function test_rebalance_reinvestingProfits() public {}

    function test_rebalance_reallocation() public {}

    // we decrease ltv in case of a loss, since the ltv goes higher than the target ltv in such a scenario
    function test_rebalance_decreassLtv() public {}

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    function _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.LendingMarketType market, uint256 amount)
        internal
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(market);
        uint256 collateral = vault.getCollateral(market);

        uint256 target = targetLtv[market].mulWadDown(amount + collateral);

        assertGt(target, debt, "target not greater than debt for supply borrow");

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[market]);
    }

    function _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.LendingMarketType market, uint256 amount)
        internal
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(market);
        uint256 collateral = vault.getCollateral(market);

        uint256 target = targetLtv[market].mulWadDown(amount + collateral);

        assertLt(target, debt, "target not less than debt for repay withdraw");

        // calculate the flashloan amount needed
        flashLoanAmount = (debt - target).divWadDown(C.ONE - targetLtv[market]);
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
}
