// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scWETHv2Keeper} from "src/steth/scWETHv2Keeper.sol";
import {scWETHv2} from "src/steth/scWETHv2.sol";
import {PriceConverter} from "src/steth/scWETHv2.sol";
import {IScETHPriceConverter} from "src/steth/priceConverter/IPriceConverter.sol";
import {Constants as C} from "src/lib/Constants.sol";
import {ZeroAddress, ProtocolNotSupported} from "src/errors/scErrors.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {AaveV3ScWethAdapter} from "src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";

contract scWETHv2KeeperTest is Test {
    using FixedPointMathLib for uint256;

    event TargetUpdated(address indexed admin, address newTarget);
    event OperatorChanged(address indexed admin, address indexed oldOperator, address indexed newOperator);

    uint256 constant AAVEV3_ADAPTER_ID = 1;
    uint256 constant COMPOUNDV3_ADAPTER_ID = 2;

    address admin = address(0x01);
    address operator = address(0x02);

    scWETHv2 target;
    scWETHv2Keeper keeper;
    IScETHPriceConverter priceConverter;
    IERC20 weth = IERC20(C.WETH);
    IERC20 wstEth = IERC20(C.WSTETH);

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20068274);

        target = scWETHv2(payable(MainnetAddresses.SCWETHV2));
        priceConverter = target.converter();

        keeper = new scWETHv2Keeper(target, admin, operator);

        bytes32 keeperRole = target.KEEPER_ROLE();
        vm.prank(MainnetAddresses.MULTISIG);
        target.grantRole(keeperRole, address(keeper));
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(keeper.target()), address(target));

        assertEq(keeper.hasRole(keeper.DEFAULT_ADMIN_ROLE(), admin), true);
        assertEq(keeper.hasRole(keeper.OPERATOR_ROLE(), operator), true);
    }

    function test_constructor_revertsIfTargetIsZeroAddress() public {
        scWETHv2 zeroAddress = scWETHv2(payable(0));

        vm.expectRevert(ZeroAddress.selector);
        new scWETHv2Keeper(zeroAddress, admin, operator);
    }

    function test_constructor_revertsIfAdminIsZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new scWETHv2Keeper(target, address(0), operator);
    }

    function test_constructor_revertsIfOperatorIsZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new scWETHv2Keeper(target, admin, address(0));
    }

    /// #setTarget ///

    function test_setTarget_revertsICallerIsNotAdmin() public {
        scWETHv2 newTarget = scWETHv2(payable(address(0x03)));

        bytes memory err = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), keeper.DEFAULT_ADMIN_ROLE()
        );
        vm.expectRevert(err);
        keeper.setTarget(newTarget);
    }

    function test_setTarget_revertsIfNewTargetIsZeroAddress() public {
        scWETHv2 zeroTarget = scWETHv2(payable(address(0)));

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(admin);
        keeper.setTarget(zeroTarget);
    }

    function test_setTarget_updatesTarget() public {
        scWETHv2 newTarget = scWETHv2(payable(address(0x03)));

        vm.prank(admin);
        keeper.setTarget(newTarget);

        assertEq(address(keeper.target()), address(newTarget));
    }

    function test_setTarget_emitsEvent() public {
        scWETHv2 newTarget = scWETHv2(payable(address(0x03)));

        vm.expectEmit(true, true, true, true);
        emit TargetUpdated(admin, address(newTarget));

        vm.prank(admin);
        keeper.setTarget(newTarget);
    }

    /// #changeOperator ///

    function test_changeOperator_revertsIfCallerIsNotAdmin() public {
        address from = operator;
        address to = address(0x03);

        bytes memory err = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), keeper.DEFAULT_ADMIN_ROLE()
        );
        vm.expectRevert(err);
        keeper.changeOperator(from, to);
    }

    function test_changeOperator_revertsIfFromIsZeroAddress() public {
        address from = address(0);
        address to = address(0x03);

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(admin);
        keeper.changeOperator(from, to);
    }

    function test_changeOperator_revertsIfToIsZeroAddress() public {
        address from = operator;
        address to = address(0);

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(admin);
        keeper.changeOperator(from, to);
    }

    function test_changeOperator_updatesOperator() public {
        address from = operator;
        address to = address(0x03);

        vm.prank(admin);
        keeper.changeOperator(from, to);

        assertEq(keeper.hasRole(keeper.OPERATOR_ROLE(), from), false);
        assertEq(keeper.hasRole(keeper.OPERATOR_ROLE(), to), true);
    }

    function test_changeOperator_emitsEvent() public {
        address from = operator;
        address to = address(0x03);

        vm.expectEmit(true, true, true, true);
        emit OperatorChanged(admin, from, to);

        vm.prank(admin);
        keeper.changeOperator(from, to);
    }

    /// #invest ///

    function test_invest_revertsIfCallerIsNotOperator() public {
        uint256 flashLoanAmount = 0;
        bytes[] memory multicallData;
        uint256 supplyLeftoverWstEthToAdapterId = 0;

        bytes memory err = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), keeper.OPERATOR_ROLE()
        );
        vm.expectRevert(err);
        keeper.invest(flashLoanAmount, multicallData, supplyLeftoverWstEthToAdapterId);
    }

    function test_invest_revertsIfProtocolIsNotSupported() public {
        uint256 flashLoanAmount = 0;
        bytes[] memory multicallData;

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, 69));
        vm.prank(operator);
        keeper.invest(flashLoanAmount, multicallData, 69);
    }

    function test_invest_targetHasNoWstEthAfterSucessfulRebalance() public {
        // fact: at the block height of the fork, only aave v3 is used with target ltv of 0.9
        // also at the block height of the fork, target has 45.831301954232015928 weth balance
        assertEq(weth.balanceOf(address(target)), 45.831301954232015928e18, "initial weth balance");

        uint256 float = weth.balanceOf(address(target));
        uint256 minRequiredFloat = target.minimumFloatAmount();

        uint256 investAmount = float - minRequiredFloat;
        assertTrue(investAmount > 0, "investAmount must be greater than 0");

        uint256 targetLtv = 0.9e18;
        // all values are in eth
        uint256 flashLoanAmount = investAmount.divWadDown(C.ONE - targetLtv) - investAmount;
        uint256 collateral = priceConverter.wstEthToEth(target.getCollateral(AAVEV3_ADAPTER_ID));
        uint256 expectedColalteral = collateral + investAmount + flashLoanAmount;
        uint256 expectedDebt = targetLtv.mulWadDown(expectedColalteral);

        uint256 supplyWstEthAmount = priceConverter.ethToWstEth(investAmount + flashLoanAmount);

        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeCall(scWETHv2.swapWethToWstEth, investAmount + flashLoanAmount);
        multicallData[1] = abi.encodeCall(scWETHv2.supplyAndBorrow, (1, supplyWstEthAmount, flashLoanAmount));

        vm.prank(operator);
        keeper.invest(flashLoanAmount, multicallData, AAVEV3_ADAPTER_ID);

        assertApproxEqAbs(weth.balanceOf(address(target)), minRequiredFloat, 1, "min required float");
        assertApproxEqRel(target.totalDebt(), expectedDebt, 0.001e18, "target debt");
        assertApproxEqRel(
            priceConverter.wstEthToEth(target.totalCollateral()), expectedColalteral, 0.001e18, "target collateral"
        );
        assertEq(wstEth.balanceOf(address(target)), 0, "wstEth balance");
    }

    function test_invest_leftoverWstEthIsSentToCorrectAdapter() public {
        // fact: at the block height of the fork, only aave v3 is used with target ltv of 0.9
        // also at the block height of the fork, target has 45.831301954232015928 weth balance
        assertEq(weth.balanceOf(address(target)), 45.831301954232015928e18, "initial weth balance");

        assertTrue(target.isSupported(COMPOUNDV3_ADAPTER_ID), "compound v3 is not supported");
        assertEq(target.getCollateral(COMPOUNDV3_ADAPTER_ID), 0, "initial compound v3 collateral");

        // all values are in eth
        uint256 investAmount = weth.balanceOf(address(target)) - target.minimumFloatAmount();
        uint256 flashLoanAmount = investAmount.divWadDown(C.ONE - 0.9e18) - investAmount;
        uint256 supplyWstEthAmount = priceConverter.ethToWstEth(investAmount + flashLoanAmount);

        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeCall(scWETHv2.swapWethToWstEth, investAmount + flashLoanAmount);
        multicallData[1] = abi.encodeCall(scWETHv2.supplyAndBorrow, (1, supplyWstEthAmount, flashLoanAmount));

        // next call is reverted because of compound v3 borrow too small restriction
        // however, the test serves the purpose of checking if the leftover wstEth is sent to the correct adapter
        vm.prank(operator);
        vm.expectRevert(bytes4(keccak256("BorrowTooSmall()")));
        keeper.invest(flashLoanAmount, multicallData, COMPOUNDV3_ADAPTER_ID);
    }

    /// #calculateInvestParams ///

    function test_calculateInvestParams_revertsIfThereIsNothingToInvest() public {
        uint256[] memory adapterIds = new uint256[](1);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;
        uint256[] memory targetLtvs = new uint256[](1);
        targetLtvs[0] = 0.9e18;

        // set min required float equal to the current target float to make sure there is nothing to invest
        uint256 currentFloat = weth.balanceOf(address(target));
        vm.prank(MainnetAddresses.MULTISIG);
        target.setMinimumFloatAmount(currentFloat);

        vm.expectRevert(scWETHv2Keeper.NoNeedToInvest.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfInputLengthIsZero() public {
        uint256[] memory adapterIds = new uint256[](0);
        uint256[] memory allocations = new uint256[](0);
        uint256[] memory targetLtvs = new uint256[](0);

        vm.expectRevert(scWETHv2Keeper.InvalidInputParameters.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfAdapterIdsAndAllocationsLengthsAreNotEqual() public {
        uint256[] memory adapterIds = new uint256[](1);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 1e18;
        allocations[1] = 0;
        uint256[] memory targetLtvs = new uint256[](1);

        vm.expectRevert(scWETHv2Keeper.InvalidInputParameters.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfAllocationsAndTargetLtsLengthsAreNotEqual() public {
        uint256[] memory adapterIds = new uint256[](1);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;
        uint256[] memory targetLtvs = new uint256[](2);
        targetLtvs[0] = 0.9e18;
        targetLtvs[1] = 0;

        vm.expectRevert(scWETHv2Keeper.InvalidInputParameters.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfAllocationsDoNotSumToOne() public {
        uint256[] memory adapterIds = new uint256[](2);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        adapterIds[1] = COMPOUNDV3_ADAPTER_ID;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.8e18;
        allocations[1] = 0.1e18;
        uint256[] memory targetLtvs = new uint256[](2);
        targetLtvs[0] = 0.9e18;
        targetLtvs[1] = 0.5e18;

        vm.expectRevert(scWETHv2Keeper.AllocationsMustSumToOne.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfAllocationIsZero() public {
        uint256[] memory adapterIds = new uint256[](2);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        adapterIds[1] = 2;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 1e18;
        allocations[1] = 0;
        uint256[] memory targetLtvs = new uint256[](2);
        targetLtvs[0] = 0.9e18;
        targetLtvs[1] = 0.5e18;

        vm.expectRevert(scWETHv2Keeper.ZeroAllocation.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfProtocolIsNotSupported() public {
        uint256[] memory adapterIds = new uint256[](1);
        adapterIds[0] = 69;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;
        uint256[] memory targetLtvs = new uint256[](1);
        targetLtvs[0] = 0.9e18;

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, 69));
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_revertsIfLtvIsZero() public {
        uint256[] memory adapterIds = new uint256[](1);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;
        uint256[] memory targetLtvs = new uint256[](1);
        targetLtvs[0] = 0;

        vm.expectRevert(scWETHv2Keeper.ZeroTargetLtv.selector);
        keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
    }

    function test_calculateInvestParams_returnsCorrectDataForSingleProtocol() public {
        uint256[] memory adapterIds = new uint256[](1);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;
        uint256[] memory targetLtvs = new uint256[](1);
        targetLtvs[0] = 0.9e18;
        // fact: at the block height of the fork, only aave v3 is used with target ltv of 0.9
        // also at the block height of the fork, target has 45.831301954232015928 weth balance
        assertEq(weth.balanceOf(address(target)), 45.831301954232015928e18, "initial weth balance");

        // all values are in eth
        uint256 investAmount = weth.balanceOf(address(target)) - target.minimumFloatAmount();
        uint256 flashLoanAmount = investAmount.divWadDown(C.ONE - targetLtvs[0]) - investAmount;
        uint256 collateral = priceConverter.wstEthToEth(target.getCollateral(AAVEV3_ADAPTER_ID));
        uint256 expectedColalteral = collateral + investAmount + flashLoanAmount;
        uint256 expectedDebt = targetLtvs[0].mulWadDown(expectedColalteral);

        // execute rebalance
        vm.startPrank(operator);
        (, uint256 totalFlashLoanAmount, bytes[] memory multicallData) =
            keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
        keeper.invest(totalFlashLoanAmount, multicallData, AAVEV3_ADAPTER_ID);

        // assert results
        assertApproxEqAbs(weth.balanceOf(address(target)), target.minimumFloatAmount(), 1, "min required float");
        assertApproxEqRel(target.totalDebt(), expectedDebt, 0.001e18, "target debt");
        assertApproxEqRel(
            priceConverter.wstEthToEth(target.totalCollateral()), expectedColalteral, 0.001e18, "target collateral"
        );
        assertEq(wstEth.balanceOf(address(target)), 0, "wstEth balance");
    }

    function test_calculateInvestParams_returnsCorrectDataForMultipleProtocols() public {
        uint256[] memory adapterIds = new uint256[](2);
        adapterIds[0] = AAVEV3_ADAPTER_ID;
        adapterIds[1] = 2; // 2 is for compound
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.5e18;
        allocations[1] = 0.5e18;
        uint256[] memory targetLtvs = new uint256[](2);
        targetLtvs[0] = 0.9e18;
        targetLtvs[1] = 0.5e18;
        // fact: at the block height of the fork, only aave v3 is used with target ltv of 0.9
        // also at the block height of the fork, target has 45.831301954232015928 weth balance
        assertEq(weth.balanceOf(address(target)), 45.831301954232015928e18, "initial weth balance");

        // all values are in eth
        uint256 investAmount = weth.balanceOf(address(target)) - target.minimumFloatAmount();
        uint256 investIntoAaveV3 =
            investAmount.mulDivDown(allocations[0], C.ONE - targetLtvs[0]) - investAmount.mulWadDown(allocations[0]);
        uint256 investIntoCompoundV3 =
            investAmount.mulDivDown(allocations[1], C.ONE - targetLtvs[1]) - investAmount.mulWadDown(allocations[1]);
        uint256 flashLoanAmount = investIntoAaveV3 + investIntoCompoundV3;

        uint256 collateral = priceConverter.wstEthToEth(target.totalCollateral());
        uint256 expectedColalteral = collateral + investAmount + flashLoanAmount;
        uint256 expectedDebt =
            targetLtvs[0].mulWadDown(investIntoAaveV3 + collateral) + targetLtvs[1].mulWadDown(investIntoCompoundV3);

        // execute rebalance
        vm.startPrank(operator);
        (, uint256 totalFlashLoanAmount, bytes[] memory multicallData) =
            keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);
        keeper.invest(totalFlashLoanAmount, multicallData, AAVEV3_ADAPTER_ID);

        // assert results
        assertApproxEqAbs(weth.balanceOf(address(target)), target.minimumFloatAmount(), 1, "min required float");
        assertApproxEqRel(target.totalDebt(), expectedDebt, 0.01e18, "target debt");
        assertApproxEqRel(
            priceConverter.wstEthToEth(target.totalCollateral()), expectedColalteral, 0.001e18, "target collateral"
        );
        assertEq(wstEth.balanceOf(address(target)), 0, "wstEth balance");
        assertApproxEqRel(
            priceConverter.wstEthToEth(target.getCollateral(AAVEV3_ADAPTER_ID)),
            investIntoAaveV3.divWadDown(targetLtvs[0]) + collateral,
            0.0001e18,
            "aave collateral"
        );
        assertApproxEqRel(
            priceConverter.wstEthToEth(target.getCollateral(2)),
            investIntoCompoundV3.divWadDown(targetLtvs[1]),
            0.0001e18,
            "compound collateral"
        );
    }
}
