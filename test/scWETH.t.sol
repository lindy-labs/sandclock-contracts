// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {Errors} from "aave-v3/protocol/libraries/helpers/Errors.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {sc4626} from "../src/sc4626.sol";
import "../src/errors/scWETHErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    // dummy users
    address constant alice = address(0x06);
    uint256 boundMinimum = 1e10; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETH vault;
    uint256 initAmount = 100e18;

    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    IAToken aToken;
    ERC20 debtToken;
    IPool aavePool;
    ICurvePool curvePool;
    uint256 slippageTolerance = 0.99e18;
    uint256 maxLtv;
    uint256 targetLtv = 0.7e18;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16784444);

        vault = new scWETH(address(C.WETH), admin,  targetLtv, slippageTolerance);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();

        maxLtv = vault.getMaxLtv();

        aToken = vault.aToken();
        debtToken = vault.variableDebtToken();
        aavePool = vault.aavePool();
        curvePool = vault.curvePool();
    }

    function test_constructor() public {
        assertEq(aavePool.getUserEMode(address(vault)), 1, "Efficiency mode not 1");
        assertEq(vault.treasury(), admin, "treasury not set");
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true, "admin role not set");
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), admin), true, "keeper role not set");
        assertEq(vault.targetLtv(), targetLtv, "targetLtv not set");
        assertEq(vault.slippageTolerance(), slippageTolerance, "slippageTolerance not set");
    }

    function test_constructor_invalidAdmin() public {
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        vault = new scWETH(address(weth), address(0x00),  targetLtv, slippageTolerance);
    }

    function test_constructor_invalidTargetLtv() public {
        vm.expectRevert(bytes4(keccak256("InvalidTargetLtv()")));
        vault = new scWETH(address(weth), admin,  0.9e18, slippageTolerance);
    }

    function test_constructor_invalidSlippageTolerance() public {
        vm.expectRevert(bytes4(keccak256("InvalidSlippageTolerance()")));
        vault = new scWETH(address(weth), admin,  targetLtv, 1.01e18);
    }

    function test_setPerformanceFee() public {
        uint256 fee = 1000;
        vault.setPerformanceFee(fee);
        assertEq(vault.performanceFee(), fee);

        // revert if called by another user
        vm.expectRevert(0x06d919f2);
        vm.prank(alice);
        vault.setPerformanceFee(fee);

        vm.expectRevert(bytes4(keccak256("FeesTooHigh()")));
        vault.setPerformanceFee(1.1e18);
    }

    function test_setTreasury() public {
        address newTreasury = alice;
        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury);

        // revert if called by another user
        vm.expectRevert(0x06d919f2);
        vm.prank(alice);
        vault.setTreasury(address(this));

        vm.expectRevert(bytes4(keccak256("TreasuryCannotBeZero()")));
        vault.setTreasury(address(0x00));
    }

    function test_setSlippageTolerance() public {
        vault.setSlippageTolerance(0.5e18);
        assertEq(vault.slippageTolerance(), 0.5e18, "slippageTolerance not set");

        // revert if called by another user
        vm.expectRevert(sc4626.CallerNotAdmin.selector);
        vm.prank(alice);
        vault.setSlippageTolerance(0.5e18);

        vm.expectRevert(bytes4(keccak256("InvalidSlippageTolerance()")));
        vault.setSlippageTolerance(1.1e18);
    }

    function test_setExchangeProxyAddress() public {
        address newExchangeProxy = alice;
        vault.setExchangeProxyAddress(newExchangeProxy);
        assertEq(vault.xrouter(), newExchangeProxy);

        // revert if called by another user
        vm.expectRevert(sc4626.CallerNotAdmin.selector);
        vm.prank(alice);
        vault.setExchangeProxyAddress(alice);

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        vault.setExchangeProxyAddress(address(0x00));
    }

    function test_setStEThToEthPriceFeed() public {
        address newStEthPriceFeed = alice;
        vault.setStEThToEthPriceFeed(newStEthPriceFeed);
        assertEq(address(vault.stEThToEthPriceFeed()), newStEthPriceFeed);

        // revert if called by another user
        vm.expectRevert(sc4626.CallerNotAdmin.selector);
        vm.prank(alice);
        vault.setStEThToEthPriceFeed(newStEthPriceFeed);

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        vault.setStEThToEthPriceFeed(address(0x00));
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

    function testFail_Deposit_WithInsufficientApproval(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount, address(this));
    }

    function testFail_Withdraw(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.withdraw(amount, address(this), address(this));
    }

    function testFail_Redeem_WithInsufficientBalance(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.redeem(amount, address(this), address(this));
    }

    function testFail_Withdraw_WithNoBalance(uint256 amount) public {
        if (amount == 0) amount = 1;
        vault.withdraw(amount, address(this), address(this));
    }

    function testFail_Redeem_WithNoBalance(uint256 amount) public {
        vault.redeem(amount, address(this), address(this));
    }

    function testFail_Deposit_WithNoApproval(uint256 amount) public {
        vault.deposit(amount, address(this));
    }

    function test_atomic_deposit_invest_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e22); //max ~$280m flashloan
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        uint256 shares = vault.deposit(amount, address(this));

        _depositChecks(amount, preDepositBal);

        vault.depositIntoStrategy();

        // account for value loss if stETH worth less than ETH
        (, int256 price,,,) = vault.stEThToEthPriceFeed().latestRoundData();
        amount = amount.mulWadDown(uint256(price));

        // account for unrealized slippage loss
        amount = amount.mulWadDown(slippageTolerance);

        assertApproxEqRel(vault.totalAssets(), amount, 0.01e18);
        assertEq(vault.balanceOf(address(this)), shares);
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(address(this))), amount, 0.01e18);

        vault.redeem(shares, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertApproxEqRel(weth.balanceOf(address(this)), amount, 0.01e18);
    }

    function test_twoDeposits_invest_twoRedeems(uint256 depositAmount1, uint256 depositAmount2) public {
        depositAmount1 = bound(depositAmount1, boundMinimum, 10000 ether);
        depositAmount2 = bound(depositAmount2, boundMinimum, 10000 ether);

        uint256 minDelta = 0.017e18;

        uint256 shares1 = _depositToVault(address(this), depositAmount1);
        uint256 shares2 = _depositToVault(alice, depositAmount2);

        vault.depositIntoStrategy();

        uint256 ltv = vault.targetLtv();

        uint256 expectedRedeem = vault.previewRedeem(shares1 / 2);
        vault.redeem(shares1 / 2, address(this), address(this));
        assertApproxEqRel(weth.balanceOf(address(this)), expectedRedeem, minDelta, "redeem1");

        assertApproxEqRel(vault.getLtv(), ltv, 0.013e18, "ltv");

        expectedRedeem = vault.previewRedeem(shares2 / 2);
        vm.prank(alice);
        vault.redeem(shares2 / 2, alice, alice);
        assertApproxEqRel(weth.balanceOf(alice), expectedRedeem, minDelta, "redeem2");

        assertApproxEqRel(vault.getLtv(), ltv, 0.01e18, "ltv");

        uint256 initBalance = weth.balanceOf(address(this));
        expectedRedeem = vault.previewRedeem(shares1 / 2);
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        assertApproxEqRel(weth.balanceOf(address(this)) - initBalance, expectedRedeem, minDelta, "redeem3");
        assertApproxEqRel(vault.getLtv(), ltv, 0.01e18, "ltv");

        initBalance = weth.balanceOf(alice);
        expectedRedeem = vault.previewRedeem(shares2 / 2);
        uint256 remainingShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(remainingShares, alice, alice);

        assertApproxEqRel(weth.balanceOf(alice) - initBalance, expectedRedeem, 0.025e18, "redeem4");

        assertEq(vault.getLtv(), 0);
    }

    function test_leverageUp(uint256 amount, uint256 newLtv) public {
        amount = bound(amount, boundMinimum, 1e20);
        _depositToVault(address(this), amount);
        vault.depositIntoStrategy();
        newLtv = bound(newLtv, vault.getLtv() + 1e15, maxLtv - 0.001e18);
        vault.changeLeverage(newLtv);
        assertApproxEqRel(vault.getLtv(), newLtv, 0.01e18, "leverage change failed");
    }

    function test_leverageDown(uint256 amount, uint256 newLtv) public {
        amount = bound(amount, boundMinimum, 1e20);
        _depositToVault(address(this), amount);
        vault.depositIntoStrategy();
        newLtv = bound(newLtv, 0.01e18, vault.getLtv() - 0.01e18);
        vault.changeLeverage(newLtv);
        assertApproxEqRel(vault.getLtv(), newLtv, 0.01e18, "leverage change failed");
    }

    function test_maxLtv(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e21);
        vm.deal(address(this), amount);

        aavePool.setUserEMode(1);

        stEth.approve(address(wstEth), type(uint256).max);
        stEth.approve(address(curvePool), type(uint256).max);
        wstEth.approve(address(aavePool), type(uint256).max);
        weth.approve(address(aavePool), type(uint256).max);
        stEth.submit{value: amount}(address(0));
        wstEth.wrap(stEth.balanceOf(address(this)));
        aavePool.supply(address(wstEth), wstEth.balanceOf(address(this)), address(this), 0);

        // borrow at max ltv should fail
        vm.expectRevert(bytes(Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW));
        aavePool.borrow(address(weth), amount.mulWadDown(maxLtv), 2, 0, address(this));

        // borrow at a little less than maxLtv should pass without errors
        aavePool.borrow(address(weth), amount.mulWadDown(maxLtv - 1e16), 2, 0, address(this));
    }

    function test_withdraw_revert() public {
        vm.expectRevert(bytes4(keccak256("PleaseUseRedeemMethod()")));
        vault.withdraw(1e18, address(this), address(this));
    }

    function test_harvest(uint256 amount, uint64 tP) public {
        amount = bound(amount, boundMinimum, 1e21);
        // simulate wstETH supply interest to EULER
        uint256 timePeriod = bound(tP, 260 days, 365 days);
        uint256 annualPeriod = 365 days;
        uint256 stEthStakingApy = 0.071e18;
        uint256 stEthStakingInterest = 1e18 + stEthStakingApy.mulDivDown(timePeriod, annualPeriod);

        _depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _simulate_stEthStakingInterest(timePeriod, stEthStakingInterest);

        assertEq(vault.totalProfit(), 0);

        vault.harvest();

        uint256 minimumExpectedApy = 0.07e18;

        assertGt(
            vault.totalProfit(),
            amount.mulWadDown(minimumExpectedApy.mulDivDown(timePeriod, annualPeriod)),
            "atleast 7% APY"
        );

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertGt(
            weth.balanceOf(address(this)) - amount,
            amount.mulWadDown(minimumExpectedApy.mulDivDown(timePeriod, annualPeriod)),
            "atleast 7% APY after withdraw"
        );
    }

    function test_withdrawToVault(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        _depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _withdrawToVaultChecks(0.018e18);
    }

    function test_harvest_withdrawToVault() public {
        // amount = bound(amount, boundMinimum, 10000 ether);
        uint256 amount = 10000 ether;
        _depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        vault.harvest();

        // harvest must automatically rebalance
        assertApproxEqRel(vault.getLtv(), vault.targetLtv(), 0.001e18, "ltv not rebalanced");

        _withdrawToVaultChecks(0.025e18);

        uint256 minimumExpectedApy = 0.05e18;

        assertGt(vault.totalProfit(), amount.mulWadDown(minimumExpectedApy), "atleast 5% APY");

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertGt(
            weth.balanceOf(address(this)) - amount,
            amount.mulWadDown(minimumExpectedApy - 0.005e18),
            "atleast 5% APY after withdraw"
        );
    }

    function test_harvest_performanceFees(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        _depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _simulate_stEthStakingInterest(365 days, 1.071e18);
        vault.harvest();
    }

    function test_mint_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        uint256 shares = vault.previewMint(amount);
        vault.mint(shares, address(this));

        _depositChecks(amount, preDepositBal);

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        _redeemChecks(preDepositBal);
    }

    function test_mint_invest_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e22); //max ~$280m flashloan
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 shares = vault.previewMint(amount);
        vault.mint(shares, address(this));

        vault.depositIntoStrategy();

        // account for value loss if stETH worth less than ETH
        (, int256 price,,,) = vault.stEThToEthPriceFeed().latestRoundData();
        amount = amount.mulWadDown(uint256(price));

        // account for unrealized slippage loss
        amount = amount.mulWadDown(slippageTolerance);

        assertApproxEqRel(vault.totalAssets(), amount, 0.01e18);
        assertEq(vault.balanceOf(address(this)), shares);
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(address(this))), amount, 0.01e18);

        vault.redeem(shares, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertApproxEqRel(weth.balanceOf(address(this)), amount, 0.01e18);
    }

    function test_mint_invest_harvest_redeem(uint256 amount) public {
        vm.startPrank(alice);
        amount = bound(amount, boundMinimum, 1e22); //max ~$280m flashloan
        vm.deal(alice, amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 shares = vault.previewMint(amount);
        vault.mint(shares, alice);
        vm.stopPrank();

        vault.depositIntoStrategy();

        uint256 interest = 1.071e18;
        _simulate_stEthStakingInterest(365 days, interest);
        vault.harvest();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(alice)), 0);
        assertGt(weth.balanceOf(alice), amount, "no profits after harvest");
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
    }

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _depositChecks(uint256 amount, uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);
    }

    function _redeemChecks(uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(weth.balanceOf(address(this)), preDepositBal);
    }

    function _withdrawToVaultChecks(uint256 maxAssetsDelta) internal {
        uint256 assets = vault.totalAssets();

        assertEq(weth.balanceOf(address(vault)), 0);

        uint256 ltv = vault.getLtv();
        uint256 lev = vault.getLeverage();

        vault.withdrawToVault(assets / 2);

        // net ltv and leverage must not change after withdraw
        assertApproxEqRel(vault.getLtv(), ltv, 0.001e18);
        assertApproxEqRel(vault.getLeverage(), lev, 0.001e18);
        assertApproxEqRel(weth.balanceOf(address(vault)), assets / 2, maxAssetsDelta);

        // withdraw the remaining assets
        vault.withdrawToVault(assets / 2);

        uint256 dust = 100;
        assertLt(vault.totalDebt(), dust, "test_withdrawToVault totalDebt error");
        assertLt(vault.totalCollateralSupplied(), dust, "test_withdrawToVault totalCollateralSupplied error");
        assertApproxEqRel(weth.balanceOf(address(vault)), assets, maxAssetsDelta, "test_withdrawToVault asset balance");
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
