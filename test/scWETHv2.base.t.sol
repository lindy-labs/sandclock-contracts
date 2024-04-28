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

import {Constants as C} from "../src/lib/Constants.sol";
import {scWETHv2} from "../src/steth/scWETHv2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {IProtocolFeesCollector} from "../src/interfaces/balancer/IProtocolFeesCollector.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../src/sc4626.sol";
import {BaseV2Vault} from "../src/steth/BaseV2Vault.sol";
import {scWETHv2Helper} from "./helpers/scWETHv2Helper.sol";
import "../src/errors/scErrors.sol";

import {IAdapter} from "../src/steth/IAdapter.sol";
import {AaveV3ScWethAdapter} from "../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {EulerScWethAdapter} from "../src/steth/scWethV2-adapters/EulerScWethAdapter.sol";
import {Swapper} from "../src/steth/Swapper.sol";
import {PriceConverter} from "../src/steth/PriceConverter.sol";
import {MockAdapter} from "./mocks/adapters/MockAdapter.sol";

contract scWETHv2Base is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    event Harvested(uint256 profitSinceLastHarvest, uint256 performanceFee);
    event MinFloatAmountUpdated(address indexed user, uint256 newMinFloatAmount);
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event SuppliedAndBorrowed(uint256 adapterId, uint256 supplyAmount, uint256 borrowAmount);
    event RepaidAndWithdrawn(uint256 adapterId, uint256 repayAmount, uint256 withdrawAmount);
    event WithdrawnToVault(uint256 amount);

    uint256 baseFork;
    uint256 blockNumber = 13629397;

    address admin = address(this);
    scWETHv2 vault;
    scWETHv2Helper vaultHelper;
    PriceConverter priceConverter;
    uint256 initAmount = 100e18;

    uint256 maxLtv;
    WETH weth;
    // ILido stEth;
    IwstETH wstEth;
    // AggregatorV3Interface public stEThToEthPriceFeed;
    uint256 minimumFloatAmount;

    mapping(IAdapter => uint256) targetLtv;

    uint256 aaveV3AdapterId;
    IAdapter aaveV3Adapter;

    uint256 flashLoanFeePercent;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1.5 ether; // below this amount, aave doesn't count it as collateral

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_BASE"));
        vm.selectFork(baseFork);
        vm.rollFork(blockNumber);

        priceConverter = new PriceConverter(address(this));
        vault = _deployVaultWithDefaultParams();
        vaultHelper = new scWETHv2Helper(vault, priceConverter);

        weth = WETH(payable(address(vault.asset())));
        // stEth = ILido(C.STETH);
        wstEth = IwstETH(C.BASE_WSTETH);
        // stEThToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED);
        minimumFloatAmount = vault.minimumFloatAmount();

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        _setupAdapters();

        targetLtv[aaveV3Adapter] = 0.4e18;
    }

    function _setupAdapters() internal {
        // add adaptors
        aaveV3Adapter = new AaveV3ScWethAdapter();

        vault.addAdapter(aaveV3Adapter);

        aaveV3AdapterId = aaveV3Adapter.id();
    }

    function _deployVaultWithDefaultParams() internal returns (scWETHv2) {
        return new scWETHv2(admin, keeper, WETH(payable(C.BASE_WETH)), new Swapper(), priceConverter);
    }

    function test_supplyAndBorrow() public {
        uint256 supplyAmount = 100 ether;
        uint256 borrowAmount = supplyAmount / 2;
        deal(address(wstEth), address(vault), supplyAmount);

        // revert if called by another user
        vm.expectRevert(CallerNotKeeper.selector);
        vault.supplyAndBorrow(aaveV3AdapterId, supplyAmount, borrowAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit SuppliedAndBorrowed(aaveV3AdapterId, supplyAmount, borrowAmount);
        vault.supplyAndBorrow(aaveV3AdapterId, supplyAmount, borrowAmount);

        assertEq(ERC20(C.BASE_WSTETH).balanceOf(address(vault)), 0, "wstEth not supplied");
        assertEq(ERC20(C.BASE_WETH).balanceOf(address(vault)), borrowAmount, "weth not borrowed");
    }

    function test_repayAndWithdraw() public {
        uint256 supplyAmount = 100 ether;
        uint256 borrowAmount = supplyAmount / 2;
        deal(address(wstEth), address(vault), supplyAmount);

        hoax(keeper);
        vault.supplyAndBorrow(aaveV3AdapterId, supplyAmount, borrowAmount);

        // revert if called by another user
        hoax(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.repayAndWithdraw(aaveV3AdapterId, supplyAmount, borrowAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RepaidAndWithdrawn(aaveV3AdapterId, borrowAmount, supplyAmount);
        vault.repayAndWithdraw(aaveV3AdapterId, borrowAmount, supplyAmount);

        assertEq(ERC20(C.BASE_WSTETH).balanceOf(address(vault)), supplyAmount, "wstEth not withdrawn");
        assertEq(ERC20(C.BASE_WETH).balanceOf(address(vault)), 0, "weth not repaid");
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

    // function testBaseSwapWethToWstEth() public {
    //     Swapper swapper = new Swapper();

    //     uint256 amount = 10 ether;
    //     deal(address(weth), address(swapper), amount);

    //     hoax(keeper);
    //     swapper.baseSwapWethToWstEth(amount, 0.01e18);

    //     // assertEq(wstEth.balanceOf(address(this)), wstEthAmount, "wstEth not received");
    //     // assertEq(weth.balanceOf(address(this)), 0, "weth not transferred");
    // }

    // function testBaseSwapWstEthToWeth() public {
    //     Swapper swapper = new Swapper();

    //     uint256 amount = 10 ether;
    //     deal(address(wstEth), address(swapper), amount);

    //     hoax(keeper);
    //     swapper.baseSwapWstEthToWeth(amount, 0.01e18);

    //     // assertEq(wstEth.balanceOf(address(this)), wstEthAmount, "wstEth not received");
    //     // assertEq(weth.balanceOf(address(this)), 0, "weth not transferred");
    // }

    function test_invest_basic() public {
        // amount = bound(amount, boundMinimum, 1000 ether);
        uint256 amount = 10 ether;

        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData, uint256 totalSupplyAmount, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount);

        // deposit into strategy
        hoax(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        _floatCheck();

        // _investChecks(investAmount, priceConverter.wstEthToEth(totalSupplyAmount), totalFlashLoanAmount);
    }

    ////////////////////////////////////////// INTERNAL METHODS //////////////////////////////////////////

    function _getInvestParams(uint256 amount) internal view returns (bytes[] memory, uint256, uint256) {
        uint256 investAmount = amount;
        uint256 stEthRateTolerance = 0.992e18;

        uint256 aaveV3Amount = amount;

        uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, aaveV3Amount);

        uint256 aaveV3SupplyAmount =
            priceConverter.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 totalFlashLoanAmount = aaveV3FlashLoanAmount;
        uint256 totalSupplyAmount = aaveV3SupplyAmount;
        // if there are flash loan fees then the below code borrows the required flashloan amount plus the flashloan fees
        // but this actually increases our LTV to a little more than the target ltv (which might not be desired)

        bytes[] memory callData = new bytes[](2);

        callData[0] = abi.encodeWithSelector(
            scWETHv2.swapWethToWstEth.selector, investAmount + totalFlashLoanAmount, totalSupplyAmount
        );

        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector,
            aaveV3AdapterId,
            aaveV3SupplyAmount,
            aaveV3FlashLoanAmount.mulWadUp(1e18 + flashLoanFeePercent)
        );

        return (callData, totalSupplyAmount, totalFlashLoanAmount);
    }

    function _investChecks(uint256 amount, uint256 totalSupplyAmount, uint256 totalDebtTaken) internal {
        uint256 totalCollateral = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, amount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), amount, "totalInvested not updated");
        assertApproxEqRel(totalCollateral, totalSupplyAmount, 0.0001e18, "totalCollateral not equal totalSupplyAmount");
        assertApproxEqRel(totalDebt, totalDebtTaken, 100, "totalDebt not equal totalDebtTaken");

        uint256 aaveV3Deposited = vaultHelper.getCollateralInWeth(aaveV3Adapter) - vault.getDebt(aaveV3Adapter.id());

        assertApproxEqRel(aaveV3Deposited, amount, 0.005e18, "aaveV3 allocation not correct");

        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter), 1e18, 0.005e18, "aaveV3 allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(aaveV3Adapter), targetLtv[aaveV3Adapter], 0.005e18, "aaveV3 ltv not correct"
        );
    }

    function _calcSupplyBorrowFlashLoanAmount(IAdapter adapter, uint256 amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(adapter.id());
        uint256 collateral = vaultHelper.getCollateralInWeth(adapter);

        uint256 target = targetLtv[adapter].mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[adapter]);
    }

    function _floatCheck() internal {
        assertGe(weth.balanceOf(address(vault)), minimumFloatAmount, "float not maintained");
    }

    function _depositChecks(uint256 amount, uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18, "convertToAssets decimal assertion failed");
        assertEq(vault.totalAssets(), amount, "totalAssets assertion failed");
        assertEq(vault.balanceOf(address(this)), amount, "balanceOf assertion failed");
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount, "convertToAssets assertion failed");
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount, "weth balance assertion failed");
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        deal(address(weth), user, amount);
        vm.startPrank(user);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}
