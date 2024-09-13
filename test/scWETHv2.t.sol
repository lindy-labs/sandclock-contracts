// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import "../src/errors/scErrors.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {scWETHv2} from "../src/steth/scWETHv2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {IProtocolFeesCollector} from "../src/interfaces/balancer/IProtocolFeesCollector.sol";
import {sc4626} from "../src/sc4626.sol";
import {BaseV2Vault} from "../src/steth/BaseV2Vault.sol";
import {UniversalSwapper} from "../src/steth/swapper/UniversalSwapper.sol";
import {scWETHv2Helper} from "./helpers/scWETHv2Helper.sol";

import {IAdapter} from "../src/steth/IAdapter.sol";
import {AaveV3ScWethAdapter} from "../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {MorphoAaveV3ScWethAdapter} from "../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {Swapper} from "../src/steth/swapper/Swapper.sol";
import {ISwapper} from "../src/steth/swapper/ISwapper.sol";
import {PriceConverter} from "../src/steth/priceConverter/PriceConverter.sol";
import {MockAdapter} from "./mocks/adapters/MockAdapter.sol";

contract scWETHv2Test is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    event Harvested(uint256 profitSinceLastHarvest, uint256 performanceFee);
    event MinFloatAmountUpdated(address indexed user, uint256 newMinFloatAmount);
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event SuppliedAndBorrowed(uint256 adapterId, uint256 supplyAmount, uint256 borrowAmount);
    event RepaidAndWithdrawn(uint256 adapterId, uint256 repayAmount, uint256 withdrawAmount);
    event WithdrawnToVault(uint256 amount);

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1.5 ether; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETHv2 vault;
    scWETHv2Helper vaultHelper;
    PriceConverter priceConverter;

    uint256 maxLtv;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    uint256 minimumFloatAmount;

    mapping(IAdapter => uint256) targetLtv;

    uint256 aaveV3AdapterId;
    uint256 compoundV3AdapterId;
    uint256 morphoAdapterId;

    IAdapter aaveV3Adapter;
    IAdapter compoundV3Adapter;
    IAdapter morphoAdapter;

    uint256 flashLoanFeePercent;

    constructor() Test() {
        vm.createSelectFork(vm.envString("RPC_URL_MAINNET"));
        _setUp(17579069);
    }

    function _setUp(uint256 _blockNumber) internal {
        vm.rollFork(_blockNumber);

        weth = WETH(payable(C.WETH));
        stEth = ILido(C.STETH);
        wstEth = IwstETH(C.WSTETH);

        priceConverter = new PriceConverter(address(this));
        vault = new scWETHv2(admin, keeper, weth, new SwapperHarness(), priceConverter);
        vaultHelper = new scWETHv2Helper(vault, priceConverter);
        minimumFloatAmount = vault.minimumFloatAmount();

        _setupAdapters();

        targetLtv[aaveV3Adapter] = 0.7e18;
        targetLtv[compoundV3Adapter] = 0.7e18;
        targetLtv[morphoAdapter] = 0.7e18;
    }

    function _setupAdapters() internal {
        aaveV3Adapter = new AaveV3ScWethAdapter();
        compoundV3Adapter = new CompoundV3ScWethAdapter();
        morphoAdapter = new MorphoAaveV3ScWethAdapter();

        vault.addAdapter(aaveV3Adapter);
        vault.addAdapter(morphoAdapter);
        vault.addAdapter(compoundV3Adapter);

        aaveV3AdapterId = aaveV3Adapter.id();
        compoundV3AdapterId = compoundV3Adapter.id();
        morphoAdapterId = morphoAdapter.id();
    }

    function test_constructor() public {
        // next line was added to include constructor in coverage
        vault = new scWETHv2(admin, keeper, WETH(payable(C.WETH)), new SwapperHarness(), priceConverter);

        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true, "admin role not set");
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), keeper), true, "keeper role not set");
        assertEq(address(vault.asset()), C.WETH);
        assertEq(address(vault.balancerVault()), C.BALANCER_VAULT);
    }

    function test_whiteListOutToken() public {
        assertEq(vault.isTokenWhitelisted(vault.asset()), true, "Asset token not whitelisted");
        assertEq(vault.isTokenWhitelisted(ERC20(C.WSTETH)), true, "WstEth token not whitelisted");

        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        vault.whiteListOutToken(ERC20(C.USDC), true);

        vm.expectRevert(ZeroAddress.selector);
        vault.whiteListOutToken(ERC20(address(0x00)), true);

        vault.whiteListOutToken(ERC20(C.USDC), true);
        assertEq(vault.isTokenWhitelisted(ERC20(C.USDC)), true);

        vault.whiteListOutToken(ERC20(C.USDC), false);
        assertEq(vault.isTokenWhitelisted(ERC20(C.USDC)), false);
    }

    function test_swapTokens_TokenOutNotAllowed() public {
        uint256 amount = 10 ether;
        _depositToVault(address(this), amount);

        vm.expectRevert(abi.encodeWithSelector(TokenOutNotAllowed.selector, C.USDC));
        vm.prank(keeper);
        vault.swapTokens(address(weth), C.USDC, amount, 0, "");
    }

    function test_addAdapter() public {
        IAdapter dummyAdapter = new AaveV3ScWethAdapter();
        // must fail if not called by admin
        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        vault.addAdapter(dummyAdapter);

        // must fail if same adapter is added again (if adapter id is not unique)
        vm.expectRevert(abi.encodeWithSelector(ProtocolInUse.selector, dummyAdapter.id()));
        vault.addAdapter(dummyAdapter);

        uint256 id = IAdapter(dummyAdapter).id();
        vault.removeAdapter(id, false);
        vault.addAdapter(dummyAdapter);
        assertEq(vault.getAdapter(dummyAdapter.id()), address(dummyAdapter), "adapter not added to protocolAdapters");
        assertEq(vault.isSupported(id), true, "adapter not added to supportedProtocols");
        // Approvals
        assertEq(ERC20(C.WSTETH).allowance(address(vault), C.AAVE_V3_POOL), type(uint256).max, "allowance not set");
        assertEq(ERC20(C.WETH).allowance(address(vault), C.AAVE_V3_POOL), type(uint256).max, "allowance not set");
    }

    function test_removeAdapter_reverts() public {
        uint256 id = aaveV3AdapterId;
        // must revert if not called by admin
        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        vault.removeAdapter(id, false);

        // must revert if protocol not supported
        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, 69));
        vault.removeAdapter(69, false);

        uint256 deposit = 10 ether;
        _depositToVault(address(this), deposit);
        uint256 investAmount = deposit - minimumFloatAmount;
        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 0.6e18, 0, 0.4e18);

        // must revert if protocol has funds deposited in it
        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        vm.expectRevert(abi.encodeWithSelector(ProtocolInUse.selector, id));
        vault.removeAdapter(id, false);

        // must not revert if force is true
        vault.removeAdapter(id, true);
        assertEq(vault.getAdapter(id), address(0x00), "adapter not removed from protocolAdapters");
        assertEq(vault.isSupported(id), false, "adapter not removed from supportedProtocols");
    }

    function test_removeAdapter() public {
        uint256 id = aaveV3AdapterId;
        vault.removeAdapter(id, false);
        _removeAdapterChecks(id, C.AAVE_V3_POOL);

        id = compoundV3AdapterId;
        vault.removeAdapter(id, false);
        _removeAdapterChecks(id, C.COMPOUND_V3_COMET_WETH);
    }

    function test_claimRewards() public {
        uint256 rewardAmount = 100e18;
        MockAdapter mockAdapter = new MockAdapter(ERC20(C.EULER_REWARDS_TOKEN));
        deal(C.EULER_REWARDS_TOKEN, mockAdapter.rewardsHolder(), rewardAmount);
        vault.addAdapter(mockAdapter);

        uint256 id = mockAdapter.id();

        vm.expectRevert(CallerNotKeeper.selector);
        vault.claimRewards(id, abi.encode(rewardAmount));

        assertEq(ERC20(C.EULER_REWARDS_TOKEN).balanceOf(address(vault)), 0, "vault has EULER balance");
        vm.prank(keeper);
        vault.claimRewards(id, abi.encode(rewardAmount));
        assertEq(ERC20(C.EULER_REWARDS_TOKEN).balanceOf(address(vault)), rewardAmount, "vault has no EULER balance");
    }

    function _removeAdapterChecks(uint256 _id, address _pool) internal {
        assertEq(vault.getAdapter(_id), address(0x00), "adapter not removed from protocolAdapters");
        assertEq(vault.isSupported(_id), false, "adapter not removed from supportedProtocols");

        assertEq(ERC20(C.WSTETH).allowance(address(vault), _pool), 0, "allowance not revoked");
        assertEq(ERC20(C.WETH).allowance(address(vault), _pool), 0, "allowance not revoked");
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

    function test_setMinimumFloatAmount() public {
        uint256 newMinimumFloatAmount = 69e18;

        vm.expectEmit(true, true, true, true);
        emit MinFloatAmountUpdated(address(this), newMinimumFloatAmount);

        vault.setMinimumFloatAmount(newMinimumFloatAmount);
        assertEq(vault.minimumFloatAmount(), newMinimumFloatAmount);

        // revert if called by another user
        vm.expectRevert(CallerNotAdmin.selector);
        vm.prank(alice);
        vault.setMinimumFloatAmount(newMinimumFloatAmount);
    }

    function test_receiveFlashLoan_InvalidFlashLoanCaller() public {
        address[] memory empty;
        uint256[] memory amounts = new uint256[](1);
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

    function test_swapTokens_EulerToWeth() public {
        uint256 expectedWethAmount = 988320853404199400;

        bytes memory swapData =
            hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000003635c9adc5dea000000000000000000000000000000000000000000000000000000d941bdaa15b045e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bd9fcd98c322942075a5c3860693e9f4f03aae07b002710c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000007992ffbce5646cdd8a";

        uint256 eulerAmount = 1000e18;
        deal(C.EULER_REWARDS_TOKEN, address(vault), eulerAmount);

        vm.expectRevert(CallerNotKeeper.selector);
        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.WETH, eulerAmount, 0, swapData);

        vm.prank(keeper);
        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.WETH, eulerAmount, 0, swapData);

        assertGe(weth.balanceOf(address(vault)), expectedWethAmount, "weth not received");
        assertEq(ERC20(C.EULER_REWARDS_TOKEN).balanceOf(address(vault)), 0, "euler token not transferred out");
    }

    function test_swapTokens_WstEthToWeth() public {
        uint256 wstEthAmount = 10 ether;
        uint256 expectedWethAmount = 11115533999999999999;
        bytes memory swapData =
            hex"6af479b200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000000000000000000000000000009a774c31cfce1ae70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b7f39c581f595b53c5cb19bd0b3f8da6c935e2ca00001f4c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000513368369c646ce7f5";

        deal(address(wstEth), address(vault), wstEthAmount);
        vm.prank(keeper);
        vault.swapTokens(address(wstEth), C.WETH, wstEthAmount, 0, swapData);

        assertGe(weth.balanceOf(address(vault)), expectedWethAmount, "weth not received");
        assertEq(wstEth.balanceOf(address(vault)), 0, "wstEth not transferred out");
    }

    function test_supplyAndBorrow() public {
        uint256 supplyAmount = 100 ether;
        uint256 borrowAmount = supplyAmount / 2;
        deal(address(wstEth), address(vault), supplyAmount);

        // revert if called by another user
        vm.expectRevert(CallerNotKeeper.selector);
        vault.supplyAndBorrow(aaveV3AdapterId, supplyAmount, borrowAmount);

        vm.expectEmit(true, true, true, true);
        emit SuppliedAndBorrowed(aaveV3AdapterId, supplyAmount, borrowAmount);

        vm.prank(keeper);
        vault.supplyAndBorrow(aaveV3AdapterId, supplyAmount, borrowAmount);

        assertEq(ERC20(C.WSTETH).balanceOf(address(vault)), 0, "wstEth not supplied");
        assertEq(ERC20(C.WETH).balanceOf(address(vault)), borrowAmount, "weth not borrowed");
    }

    function test_repayAndWithdraw() public {
        uint256 supplyAmount = 100 ether;
        uint256 borrowAmount = supplyAmount / 2;
        deal(address(wstEth), address(vault), supplyAmount);

        vm.prank(keeper);
        vault.supplyAndBorrow(aaveV3AdapterId, supplyAmount, borrowAmount);

        // revert if called by another user
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.repayAndWithdraw(aaveV3AdapterId, supplyAmount, borrowAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RepaidAndWithdrawn(aaveV3AdapterId, borrowAmount, supplyAmount);
        vault.repayAndWithdraw(aaveV3AdapterId, borrowAmount, supplyAmount);

        assertEq(ERC20(C.WSTETH).balanceOf(address(vault)), supplyAmount, "wstEth not withdrawn");
        assertEq(ERC20(C.WETH).balanceOf(address(vault)), 0, "weth not repaid");
    }

    function test_invest_FloatBalanceTooLow() public {
        uint256 deposit = 100 ether;
        _depositToVault(address(this), deposit);

        uint256 investAmount = deposit - minimumFloatAmount + 1;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 0.6e18, 0, 0.4e18);

        // deposit into strategy
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FloatBalanceTooLow.selector, minimumFloatAmount - 1, minimumFloatAmount));
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
    }

    function test_invest_TooMuch() public {
        uint256 deposit = 100 ether;
        _depositToVault(address(this), deposit);

        uint256 investAmount = deposit + 1;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 0.6e18, 0, 0.4e18);

        // deposit into strategy
        vm.prank(keeper);
        vm.expectRevert(InsufficientDepositBalance.selector);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
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

    function test_maxLtv() public {
        assertEq(aaveV3Adapter.getMaxLtv(), 0.9e18, "aaveV3 Max Ltv Error");
        assertEq(compoundV3Adapter.getMaxLtv(), 0.9e18, "compoundV3 Max Ltv Error");
    }

    function test_deposit_withdraw(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        vault.deposit(amount, address(this));

        _floatCheck();
        _depositChecks(amount, preDepositBal);

        vault.withdraw(amount, address(this), address(this));

        _redeemChecks(preDepositBal);
    }

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

    function test_withdraw_by_others(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        _depositToVault(address(this), amount);

        uint256 giftAmount;
        giftAmount = bound(giftAmount, 1, amount - 1);
        vault.approve(alice, giftAmount);

        vm.startPrank(alice);
        vault.withdraw(giftAmount, alice, address(this));
        assertEq(vault.totalAssets(), amount - giftAmount);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(weth.balanceOf(address(alice)), giftAmount);

        vm.expectRevert();
        vault.withdraw(giftAmount, alice, address(this)); // no shares anymore
    }

    function test_redeem_by_others(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        _depositToVault(address(this), amount);

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

    function test_withdraw_maintainsFloat() public {
        uint256 amount = vault.minimumFloatAmount() * 5;
        _depositToVault(address(this), amount);

        // invest & create position on aave v3
        uint256 investAmount = amount - vault.minimumFloatAmount();
        uint256 flashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, investAmount);
        uint256 aaveV3SupplyAmount = priceConverter.ethToWstEth(investAmount + flashLoanAmount).mulWadDown(0.99e18);

        bytes[] memory callData = new bytes[](2);

        callData[0] = abi.encodeCall(scWETHv2.swapWethToWstEth, (investAmount + flashLoanAmount));
        callData[1] = abi.encodeCall(scWETHv2.supplyAndBorrow, (aaveV3AdapterId, aaveV3SupplyAmount, flashLoanAmount));

        vm.prank(keeper);
        vault.rebalance(investAmount, flashLoanAmount, callData);

        // withdraw more than what is already in the vault as float
        vault.withdraw(weth.balanceOf(address(vault)) + 1, address(this), address(this));

        _floatCheck();

        // withdraw everything to ensure minimum float logic doesn't apply for the vault's only/last user
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertApproxEqRel(weth.balanceOf(address(this)), amount, 0.015e18, "user's end balance");
    }

    function test_redeem_zero() public {
        vm.expectRevert("ZERO_ASSETS");
        vault.redeem(0, address(this), address(this));
    }

    function test_rebalance_emitsEvent() public {
        uint256 amount = 100 ether;
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData, uint256 totalSupplyAmount, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount, 0.6e18, 0, 0.4e18);

        vm.expectEmit(true, true, true, false);
        emit Rebalanced(totalSupplyAmount, totalFlashLoanAmount, minimumFloatAmount);

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
    }

    function test_invest_basic(uint256 amount) public {
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData, uint256 totalSupplyAmount, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount, 0.6e18, 0, 0.4e18);

        // deposit into strategy
        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        _floatCheck();

        _investChecks(investAmount, priceConverter.wstEthToEth(totalSupplyAmount), totalFlashLoanAmount, 0.6e18, 0.4e18);
    }

    function test_invest_withNonZeroFlashLoanFees() public {
        flashLoanFeePercent = 5e15; // 0.5%

        IProtocolFeesCollector balancerFeeContract = IProtocolFeesCollector(C.BALANCER_FEES_COLLECTOR);

        // change balancer flashloan fees percentage
        vm.prank(C.BALANCER_ADMIN);
        balancerFeeContract.setFlashLoanFeePercentage(flashLoanFeePercent);
        assertEq(balancerFeeContract.getFlashLoanFeePercentage(), flashLoanFeePercent);

        uint256 amount = 1000 ether;
        _depositToVault(address(this), amount);

        uint256 initialBalance = weth.balanceOf(address(balancerFeeContract));

        uint256 investAmount = amount - minimumFloatAmount;
        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 0.6e18, 0, 0.4e18);

        // must not revert (would have reverted if scWETHv2 was not paying fees)
        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        // assert fees has been paid
        uint256 expectedFees = totalFlashLoanAmount.mulWadUp(flashLoanFeePercent);
        assertEq(weth.balanceOf(address(balancerFeeContract)) - initialBalance, expectedFees, "Balancer Fees not paid");
    }

    function test_disinvest_usingMulticallsAndZeroExSwap() public {
        uint256 amount = 100 ether;
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;
        uint256 stEthRateTolerance = 0.998e18;
        uint256 compoundV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, investAmount);
        uint256 compoundV3SupplyAmount =
            priceConverter.ethToWstEth(investAmount + compoundV3FlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 minimumDust = amount.mulWadDown(0.01e18) + (amount - investAmount);

        bytes[] memory callData = new bytes[](2);
        callData[0] =
            abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, investAmount + compoundV3FlashLoanAmount);
        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, compoundV3AdapterId, compoundV3SupplyAmount, compoundV3FlashLoanAmount
        );

        // deposit into strategy
        vm.prank(keeper);
        vault.rebalance(investAmount, compoundV3FlashLoanAmount, callData);

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after invest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after invest");

        uint256 wstEthAmountToWithdraw = 10 ether;
        uint256 expectedWethAmountAfterSwap = 11115533999999999999;
        bytes memory swapData =
            hex"6af479b200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000000000000000000000000000009a774c31cfce1ae70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b7f39c581f595b53c5cb19bd0b3f8da6c935e2ca00001f4c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000513368369c646ce7f5";

        compoundV3FlashLoanAmount = expectedWethAmountAfterSwap;

        uint256 assets = vault.totalAssets();
        uint256 leverage = vaultHelper.getLeverage();

        callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(
            scWETHv2.repayAndWithdraw.selector, compoundV3AdapterId, expectedWethAmountAfterSwap, wstEthAmountToWithdraw
        );

        // swap wstEth to weth using zeroEx swap
        callData[1] = abi.encodeWithSelector(
            BaseV2Vault.swapTokens.selector, wstEth, ERC20(C.WETH), wstEthAmountToWithdraw, 0, swapData
        );

        vm.prank(keeper);
        vault.rebalance(0, expectedWethAmountAfterSwap, callData);

        _floatCheck();

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after disinvest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after disinvest");
        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "disinvest must not change total assets");
        assertGe(leverage, vaultHelper.getLeverage(), "leverage not decreased after disinvest");
    }

    function test_deposit_invest_withdraw(uint256 amount) public {
        amount = bound(amount, boundMinimum, 5000 ether);

        uint256 shares = _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 1e18, 0, 0);

        // deposit into strategy
        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        uint256 userBalance = vault.convertToAssets(shares);

        vault.withdraw(userBalance, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.balanceOf(address(this)), 0, "shares");
        assertApproxEqRel(weth.balanceOf(address(this)), userBalance, 0.01e18, "weth balance after withdraw error");
    }

    function test_deposit_invest_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1000 ether);
        uint256 shares = _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 1e18, 0, 0);

        // deposit into strategy
        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

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
        uint256 maxAssetsDelta = 0.015e18;
        _depositToVault(address(this), amount);
        _depositChecks(amount, amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 1e18, 0, 0);

        // deposit into strategy
        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        uint256 assets = priceConverter.wstEthToEth(vault.totalCollateral()) - vault.totalDebt();
        uint256 floatBalance = amount - investAmount;

        assertEq(weth.balanceOf(address(vault)), floatBalance, "float amount error");

        uint256 ltv = vaultHelper.getLtv();
        uint256 lev = vaultHelper.getLeverage();

        // test event
        vm.expectEmit(true, true, false, false);
        emit WithdrawnToVault(assets / 2);

        vm.prank(keeper);
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
        vm.prank(keeper);
        vault.withdrawToVault(assets / 2);

        _floatCheck();

        uint256 dust = 100;
        assertLt(vault.totalDebt(), dust, "test_withdrawToVault getDebt error");
        assertLt(priceConverter.wstEthToEth(vault.totalCollateral()), dust, "test_withdrawToVault getCollateral error");
        assertApproxEqRel(
            weth.balanceOf(address(vault)) - floatBalance, assets, maxAssetsDelta, "test_withdrawToVault asset balance"
        );
        assertApproxEqRel(vault.totalInvested(), investAmount - assets, 0.001e18, "totalInvested not reduced");
    }

    // we decrease ltv in case of a loss, since the ltv goes higher than the target ltv in such a scenario
    function test_disinvest(uint256 amount) public {
        amount = bound(amount, 2 ether, 1000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        uint256 minimumDust = amount.mulWadDown(0.01e18) + (amount - investAmount);

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 0.9e18, 0, 0.1e18);

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after invest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after invest");

        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);

        // disinvest to decrease the ltv on each protocol
        uint256 ltvDecrease = 0.1e18;

        uint256 aaveV3Allocation = vaultHelper.allocationPercent(aaveV3Adapter);
        uint256 compoundAllocation = vaultHelper.allocationPercent(compoundV3Adapter);

        (callData, totalFlashLoanAmount) = _getDisInvestParams(aaveV3Ltv - ltvDecrease, compoundLtv - ltvDecrease);

        uint256 assets = vault.totalAssets();
        uint256 lev = vaultHelper.getLeverage();
        uint256 ltv = vaultHelper.getLtv();

        vm.prank(keeper);
        vault.rebalance(0, totalFlashLoanAmount, callData);

        _floatCheck();

        assertApproxEqRel(
            vaultHelper.getLtv(aaveV3Adapter), aaveV3Ltv - ltvDecrease, 0.0000001e18, "aavev3 ltv not decreased"
        );
        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter),
            compoundLtv - ltvDecrease,
            0.0000001e18,
            "compoundLtv ltv not decreased"
        );
        assertApproxEqRel(vaultHelper.getLtv(), ltv - ltvDecrease, 0.01e18, "net ltv not decreased");

        assertLt(weth.balanceOf(address(vault)), minimumDust, "weth dust after disinvest");
        assertLt(wstEth.balanceOf(address(vault)), minimumDust, "wstEth dust after disinvest");
        assertApproxEqRel(vault.totalAssets(), assets, 0.005e18, "disinvest must not change total assets");
        assertGe(lev - vaultHelper.getLeverage(), 0.4e18, "leverage not decreased after disinvest");

        // allocations must not change
        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter),
            aaveV3Allocation,
            0.001e18,
            "aavev3 allocation must not change"
        );
        assertApproxEqRel(
            vaultHelper.allocationPercent(compoundV3Adapter),
            compoundAllocation,
            0.001e18,
            "compound allocation must not change"
        );
    }

    function test_reallocate_fromHigherLtvMarket_toLowerLtvMarket() public {
        uint256 amount = 1001 ether;
        _depositToVault(address(this), amount);

        uint256 investAmount = (amount - minimumFloatAmount).mulWadUp(0.9999e18);

        uint256 aaveV3Allocation = 0.7e18;
        uint256 compoundAllocation = 0.3e18;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount, aaveV3Allocation, 0, compoundAllocation);

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        uint256 aaveV3Assets = vaultHelper.getAssets(aaveV3Adapter);
        uint256 compoundAssets = vaultHelper.getAssets(compoundV3Adapter);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);

        uint256 reallocationAmount = investAmount.mulWadDown(0.1e18); // in weth

        (callData, totalFlashLoanAmount) =
            _getReallocationParamsWhenMarket1HasHigherLtv(reallocationAmount, aaveV3Assets, compoundLtv);

        vm.prank(keeper);
        vault.rebalance(0, totalFlashLoanAmount, callData);

        _floatCheck();

        _reallocationChecksWhenMarket1HasHigherLtv(
            totalAssets,
            aaveV3Allocation,
            compoundAllocation,
            aaveV3Assets,
            compoundAssets,
            aaveV3Ltv,
            compoundLtv,
            reallocationAmount
        );
    }

    function test_reallocate_fromLowerLtvMarket_toHigherLtvMarket() public {
        uint256 amount = 15000 ether;
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        uint256 aaveV3Allocation = 0.7e18;
        uint256 compoundAllocation = 0.3e18;
        targetLtv[compoundV3Adapter] = 0.5e18;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount, aaveV3Allocation, 0, compoundAllocation);

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        uint256 aaveV3Assets = vaultHelper.getAssets(aaveV3Adapter);
        uint256 compoundAssets = vaultHelper.getAssets(compoundV3Adapter);
        uint256 totalAssets = vault.totalAssets();
        uint256 aaveV3Ltv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 compoundLtv = vaultHelper.getLtv(compoundV3Adapter);

        uint256 reallocationAmount = investAmount.mulWadDown(0.1e18); // in weth

        (callData, totalFlashLoanAmount) =
            _getReallocationParamsWhenMarket1HasLowerLtv(reallocationAmount, compoundAssets, aaveV3Ltv);

        vm.prank(keeper);
        vault.rebalance(0, totalFlashLoanAmount, callData);

        _floatCheck();

        _reallocationChecksWhenMarket1HasLowerLtv(
            totalAssets, aaveV3Assets, compoundAssets, aaveV3Ltv, compoundLtv, reallocationAmount
        );
    }

    function test_invest_reinvestingProfits_performanceFees(uint256 amount) public {
        vault.setTreasury(treasury);
        amount = bound(amount, boundMinimum, 5000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount, 1e18, 0, 0);

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        uint256 altv = vaultHelper.getLtv(aaveV3Adapter);
        uint256 ltv = vaultHelper.getLtv();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        assertLt(vaultHelper.getLtv(), ltv, "ltv must decrease after simulated profits");
        assertLt(vaultHelper.getLtv(aaveV3Adapter), altv, "aavev3 ltv must decrease after simulated profits");

        (bytes[] memory callDataAfterProfits,, uint256 totalFlashLoanAmountAfterProfits) =
            _getInvestParams(0, 1e18, 0, 0);

        vm.expectEmit(true, true, false, false);
        emit Harvested(0, 0); // just testing for the event emission and not the actual numbers since the actual profit is a little tedious to simulate

        vm.prank(keeper);
        vault.rebalance(0, totalFlashLoanAmountAfterProfits, callDataAfterProfits);

        _floatCheck();

        assertApproxEqRel(altv, vaultHelper.getLtv(aaveV3Adapter), 0.0015e18, "aavev3 ltvs not reset after reinvest");

        assertApproxEqRel(ltv, vaultHelper.getLtv(), 0.005e18, "net ltv not reset after reinvest");

        uint256 balance = vault.convertToAssets(vault.balanceOf(treasury));
        uint256 profit = vault.totalProfit();
        assertApproxEqRel(balance, profit.mulWadDown(vault.performanceFee()), 0.015e18);
    }

    function test_invest_withZeroExWethToWstEthSwap() public {
        _setUp(17934941);

        vault.setTreasury(treasury);
        uint256 amount = 100 ether;
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;

        uint256 stEthRateTolerance = 0.999e18;

        uint256 aaveV3Amount = investAmount.mulWadDown(0.5e18);
        uint256 compoundAmount = investAmount.mulWadDown(0.5e18);

        uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, aaveV3Amount);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);

        uint256 aaveV3SupplyAmount =
            priceConverter.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            priceConverter.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 totalFlashLoanAmount = aaveV3FlashLoanAmount + compoundFlashLoanAmount;

        bytes[] memory callData = new bytes[](3);

        callData[0] = abi.encodeWithSelector(
            BaseV2Vault.swapTokens.selector,
            weth,
            wstEth,
            investAmount + totalFlashLoanAmount,
            1,
            hex"6af479b20000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000011e3ab8395c6e8000000000000000000000000000000000000000000000000000f97a7ede4f09e7a5b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000647f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000869584cd000000000000000000000000588ebf90cce940403c2d3650519313ed5c414cc200000000000000000000000000000000095789faafab13e98e0d8e807cdbbddf"
        );

        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector,
            aaveV3AdapterId,
            aaveV3SupplyAmount,
            aaveV3FlashLoanAmount.mulWadUp(1e18 + flashLoanFeePercent)
        );

        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector,
            compoundV3AdapterId,
            compoundSupplyAmount,
            compoundFlashLoanAmount.mulWadUp(1e18 + flashLoanFeePercent)
        );

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        _floatCheck();
        _investChecks(
            investAmount,
            priceConverter.wstEthToEth(aaveV3SupplyAmount + compoundSupplyAmount),
            totalFlashLoanAmount,
            0.5e18,
            0.5e18
        );
    }

    function test_invest_withCurveWethToWstEthSwap() public {
        _setUp(18819890);

        uint256 stEthRateTolerance = 0.999e18;

        uint256 amount = 10 ether;
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount;
        uint256 aaveV3Amount = investAmount.mulWadDown(0.8e18);
        uint256 compoundAmount = investAmount.mulWadDown(0.2e18);

        uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, aaveV3Amount);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);

        uint256 aaveV3SupplyAmount =
            priceConverter.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            priceConverter.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 totalFlashLoanAmount = aaveV3FlashLoanAmount + compoundFlashLoanAmount;
        uint256 totalWethAmount = investAmount + totalFlashLoanAmount;

        bytes[] memory callData = new bytes[](3);

        callData[0] = abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, totalWethAmount);

        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, aaveV3AdapterId, aaveV3SupplyAmount, aaveV3FlashLoanAmount
        );

        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, compoundV3AdapterId, compoundSupplyAmount, compoundFlashLoanAmount
        );

        // expect a call on curve pool to exchange weth for stETH
        vm.expectCall(
            address(Swapper(address(vault.swapper())).curvePool()),
            abi.encodeCall(ICurvePool.exchange, (0, 1, totalWethAmount, totalWethAmount))
        );

        vm.prank(keeper);
        vault.rebalance(investAmount, totalFlashLoanAmount, callData);

        _floatCheck();
        _investChecks(
            investAmount,
            priceConverter.wstEthToEth(aaveV3SupplyAmount + compoundSupplyAmount),
            totalFlashLoanAmount,
            0.8e18,
            0.2e18
        );
    }

    function test_invest_withCurveWethToWstEthSwap_switchToUpdatedSwapperOnExistingContract() public {
        _setUp(18819890);
        vault = scWETHv2(payable(0x4c406C068106375724275Cbff028770C544a1333)); // mainnet scWETHv2 address
        vaultHelper = new scWETHv2Helper(vault, priceConverter);

        uint256 amount = 10 ether;
        _depositToVault(address(this), amount);

        targetLtv[aaveV3Adapter] = 0.85e18;
        uint256 investAmount = amount - minimumFloatAmount;
        uint256 flashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, investAmount);
        uint256 totalWethAmount = investAmount + flashLoanAmount;
        uint256 supplyAmount = priceConverter.ethToWstEth(totalWethAmount).mulWadDown(0.999e18);

        bytes[] memory callData = new bytes[](2);

        callData[0] = abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, totalWethAmount);
        callData[1] =
            abi.encodeWithSelector(scWETHv2.supplyAndBorrow.selector, aaveV3AdapterId, supplyAmount, flashLoanAmount);

        uint256 totalCollateral = vault.totalCollateral();

        // change to new swapper
        Swapper swapper = new Swapper();
        vm.prank(0x6cF38285FdFAf8D67205ca444A899025b5B18e83); // admin account
        // set new swapper contract
        vault.setSwapper(swapper);

        vm.expectCall(
            address(swapper.curvePool()), abi.encodeCall(ICurvePool.exchange, (0, 1, totalWethAmount, totalWethAmount))
        );
        // try rebalance with new swapper
        vm.prank(0x397502F15E11C524F23C0c003f5E8004C1c5c71D); // keeper account
        vault.rebalance(investAmount, flashLoanAmount, callData);

        assertEq(vault.totalCollateral(), totalCollateral + supplyAmount, "funds not invested");
    }

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

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

    function _calcRepayWithdrawFlashLoanAmount(IAdapter adapter, uint256 amount, uint256 ltv)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(adapter.id());
        uint256 collateral = vaultHelper.getCollateralInWeth(adapter);

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
    ) internal view returns (bytes[] memory, uint256) {
        uint256 repayAmount = reallocationAmount.mulDivDown(vault.getDebt(aaveV3AdapterId), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        bytes[] memory callData = new bytes[](3);

        callData[0] = abi.encodeWithSelector(
            scWETHv2.repayAndWithdraw.selector, aaveV3AdapterId, repayAmount, priceConverter.ethToWstEth(withdrawAmount)
        );

        uint256 delta = (repayAmount - market2Ltv.mulWadDown(withdrawAmount)).divWadDown(1e18 - market2Ltv);
        uint256 market2SupplyAmount = withdrawAmount - delta;
        uint256 market2BorrowAmount = repayAmount - delta;

        callData[1] = abi.encodeWithSelector(
            scWETHv2.swapWstEthToWeth.selector, priceConverter.ethToWstEth(delta), vault.slippageTolerance()
        );

        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector,
            compoundV3AdapterId,
            priceConverter.ethToWstEth(market2SupplyAmount),
            market2BorrowAmount
        );

        return (callData, repayAmount);
    }

    function _getReallocationParamsWhenMarket1HasLowerLtv(
        uint256 reallocationAmount,
        uint256 market1Assets,
        uint256 market2Ltv
    ) internal view returns (bytes[] memory, uint256) {
        bytes[] memory callData = new bytes[](3);

        uint256 repayAmount = reallocationAmount.mulDivDown(vault.getDebt(compoundV3AdapterId), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        callData[0] = abi.encodeWithSelector(
            scWETHv2.repayAndWithdraw.selector,
            compoundV3AdapterId,
            repayAmount,
            priceConverter.ethToWstEth(withdrawAmount)
        );

        uint256 market2SupplyAmount = repayAmount.divWadDown(market2Ltv);
        uint256 market2BorrowAmount = repayAmount;

        uint256 delta = withdrawAmount - market2SupplyAmount;

        callData[1] = abi.encodeWithSelector(
            scWETHv2.swapWstEthToWeth.selector, priceConverter.ethToWstEth(delta), vault.slippageTolerance()
        );

        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector,
            aaveV3AdapterId,
            priceConverter.ethToWstEth(market2SupplyAmount),
            market2BorrowAmount
        );

        return (callData, repayAmount);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken

    function _getInvestParams(
        uint256 amount,
        uint256 aaveV3Allocation,
        uint256 morphoAllocation,
        uint256 compoundAllocation
    ) internal view returns (bytes[] memory, uint256, uint256) {
        uint256 investAmount = amount;
        uint256 stEthRateTolerance = 0.999e18;

        uint256 count = 0;
        if (aaveV3Allocation > 0) count++;
        if (morphoAllocation > 0) count++;
        if (compoundAllocation > 0) count++;

        require(count > 0, "No amount to invest");

        uint256 position = 1;

        uint256 totalFlashLoanAmount = 0;
        uint256 totalSupplyAmount;
        bytes[] memory callData = new bytes[](count + 1);

        if (aaveV3Allocation > 0) {
            uint256 aaveV3Amount = investAmount.mulWadDown(aaveV3Allocation);
            uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, aaveV3Amount);
            uint256 aaveV3SupplyAmount =
                priceConverter.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);

            callData[position] = abi.encodeWithSelector(
                scWETHv2.supplyAndBorrow.selector,
                aaveV3AdapterId,
                aaveV3SupplyAmount,
                aaveV3FlashLoanAmount.mulWadUp(1e18 + flashLoanFeePercent)
            );

            totalFlashLoanAmount += aaveV3FlashLoanAmount;
            totalSupplyAmount += aaveV3SupplyAmount;
            position++;
        }

        if (morphoAllocation > 0) {
            uint256 morphoAmount = investAmount.mulWadDown(morphoAllocation);
            uint256 morphoFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(morphoAdapter, morphoAmount);

            uint256 morphoSupplyAmount =
                priceConverter.ethToWstEth(morphoAmount + morphoFlashLoanAmount).mulWadDown(stEthRateTolerance);

            callData[position] = abi.encodeWithSelector(
                scWETHv2.supplyAndBorrow.selector,
                morphoAdapterId,
                morphoSupplyAmount,
                morphoFlashLoanAmount.mulWadUp(1e18 + flashLoanFeePercent)
            );

            totalFlashLoanAmount += morphoFlashLoanAmount;
            totalSupplyAmount += morphoSupplyAmount;
            position++;
        }

        if (compoundAllocation > 0) {
            uint256 compoundAmount = investAmount.mulWadDown(compoundAllocation);
            uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);
            uint256 compoundSupplyAmount =
                priceConverter.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

            callData[position] = abi.encodeWithSelector(
                scWETHv2.supplyAndBorrow.selector,
                compoundV3AdapterId,
                compoundSupplyAmount,
                compoundFlashLoanAmount.mulWadUp(1e18 + flashLoanFeePercent)
            );

            totalFlashLoanAmount += compoundFlashLoanAmount;
            totalSupplyAmount += compoundSupplyAmount;
            position++;
        }

        // if there are flash loan fees then the below code borrows the required flashloan amount plus the flashloan fees
        // but this actually increases our LTV to a little more than the target ltv (which might not be desired)
        callData[0] = abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, investAmount + totalFlashLoanAmount);

        return (callData, totalSupplyAmount, totalFlashLoanAmount);
    }

    /// @return : repayWithdrawParams
    function _getDisInvestParams(uint256 newAaveV3Ltv, uint256 newCompoundLtv)
        internal
        view
        returns (bytes[] memory, uint256)
    {
        uint256 aaveV3FlashLoanAmount = _calcRepayWithdrawFlashLoanAmount(aaveV3Adapter, 0, newAaveV3Ltv);
        uint256 compoundFlashLoanAmount = _calcRepayWithdrawFlashLoanAmount(compoundV3Adapter, 0, newCompoundLtv);

        bytes[] memory callData = new bytes[](3);

        callData[0] = abi.encodeWithSelector(
            scWETHv2.repayAndWithdraw.selector,
            aaveV3AdapterId,
            aaveV3FlashLoanAmount,
            priceConverter.ethToWstEth(aaveV3FlashLoanAmount)
        );
        callData[1] = abi.encodeWithSelector(
            scWETHv2.repayAndWithdraw.selector,
            compoundV3AdapterId,
            compoundFlashLoanAmount,
            priceConverter.ethToWstEth(compoundFlashLoanAmount)
        );
        callData[2] =
            abi.encodeWithSelector(scWETHv2.swapWstEthToWeth.selector, type(uint256).max, vault.slippageTolerance());

        return (callData, aaveV3FlashLoanAmount + compoundFlashLoanAmount);
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
        uint256 aaveV3Allocation,
        uint256 compoundAllocation
    ) internal {
        uint256 totalCollateral = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, amount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), amount, "totalInvested not updated");
        assertApproxEqRel(totalCollateral, totalSupplyAmount, 0.0001e18, "totalCollateral not equal totalSupplyAmount");
        assertApproxEqRel(totalDebt, totalDebtTaken, 100, "totalDebt not equal totalDebtTaken");

        uint256 aaveV3Deposited = vaultHelper.getCollateralInWeth(aaveV3Adapter) - vault.getDebt(aaveV3AdapterId);
        uint256 compoundDeposited =
            vaultHelper.getCollateralInWeth(compoundV3Adapter) - vault.getDebt(compoundV3AdapterId);

        assertApproxEqRel(
            aaveV3Deposited, amount.mulWadDown(aaveV3Allocation), 0.005e18, "aaveV3 allocation not correct"
        );
        assertApproxEqRel(
            compoundDeposited, amount.mulWadDown(compoundAllocation), 0.005e18, "compound allocation not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter),
            aaveV3Allocation,
            0.005e18,
            "aaveV3 allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(compoundV3Adapter),
            compoundAllocation,
            0.005e18,
            "compound allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(aaveV3Adapter), targetLtv[aaveV3Adapter], 0.005e18, "aaveV3 ltv not correct"
        );
        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter), targetLtv[compoundV3Adapter], 0.005e18, "compound ltv not correct"
        );
    }

    function _reallocationChecksWhenMarket1HasHigherLtv(
        uint256 totalAssets,
        uint256 inititalAaveV3Allocation,
        uint256 initialCompoundAllocation,
        uint256 inititalAaveV3Assets,
        uint256 initialCompoundAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialCompoundLtv,
        uint256 reallocationAmount
    ) internal {
        assertApproxEqRel(
            vaultHelper.allocationPercent(aaveV3Adapter),
            inititalAaveV3Allocation - 0.1e18,
            0.005e18,
            "aavev3 allocation error"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(compoundV3Adapter),
            initialCompoundAllocation + 0.1e18,
            0.005e18,
            "compound allocation error"
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
            vaultHelper.getAssets(compoundV3Adapter),
            initialCompoundAssets + reallocationAmount,
            0.001e18,
            "compound assets not increased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs should not change
        assertApproxEqRel(vaultHelper.getLtv(aaveV3Adapter), initialAaveV3Ltv, 0.001e18, "aavev3 ltv must not change");
        assertApproxEqRel(
            vaultHelper.getLtv(compoundV3Adapter), initialCompoundLtv, 0.001e18, "compound ltv must not change"
        );
    }

    function _reallocationChecksWhenMarket1HasLowerLtv(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialCompoundAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialCompoundLtv,
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
            vaultHelper.getAssets(compoundV3Adapter),
            initialCompoundAssets - reallocationAmount,
            0.001e18,
            "compound assets not decreased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(vaultHelper.getLtv(aaveV3Adapter), initialAaveV3Ltv, 0.001e18, "aavev3 ltv must not change");

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

contract SwapperHarness is Swapper {
    function swapRouter() public pure override(ISwapper, UniversalSwapper) returns (address) {
        return C.ZERO_EX_ROUTER;
    }
}
