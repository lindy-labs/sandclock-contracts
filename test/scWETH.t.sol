// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scWETH as Vault} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {Errors} from "aave-v3/protocol/libraries/helpers/Errors.sol";
import "../src/errors/scWETHErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    // dummy users
    address constant alice = address(0x06);
    uint256 boundMinimum = 1e10; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    Vault vault;
    uint256 initAmount = 100e18;

    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    IAToken aToken;
    ERC20 debtToken;
    IPool aavePool;
    ICurvePool curvePool;
    uint256 slippageTolerance;
    uint256 maxLtv;
    uint256 targetLtv;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16784444);

        vault = new Vault(admin);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();

        slippageTolerance = vault.slippageTolerance();
        maxLtv = vault.getMaxLtv();
        targetLtv = vault.targetLtv();

        aToken = vault.aToken();
        debtToken = vault.variableDebtToken();
        aavePool = vault.aavePool();
        curvePool = vault.curvePool();
    }

    function test_constructor() public {
        assertEq(aavePool.getUserEMode(address(vault)), vault.EMODE_ID(), "E mode not set");
        assertEq(vault.treasury(), admin, "treasury not set");
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true, "admin role not set");
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), admin), true, "keeper role not set");
    }

    function test_setPerformanceFee() public {
        uint256 fee = 1000;
        vault.setPerformanceFee(fee);
        assertEq(vault.performanceFee(), fee);

        // revert if called by another user
        vm.expectRevert(
            bytes(
                "AccessControl: account 0x0000000000000000000000000000000000000006 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
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
        vm.expectRevert(
            bytes(
                "AccessControl: account 0x0000000000000000000000000000000000000006 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
        vm.prank(alice);
        vault.setTreasury(address(this));

        vm.expectRevert(bytes4(keccak256("TreasuryCannotBeZero()")));
        vault.setTreasury(address(0x00));
    }

    function test_setSlippageTolerance() public {
        vault.setSlippageTolerance(0.5e18);
        assertEq(vault.slippageTolerance(), 0.5e18, "slippageTolerance not set");

        // revert if called by another user
        vm.expectRevert(
            bytes(
                "AccessControl: account 0x0000000000000000000000000000000000000006 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
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
        vm.expectRevert(
            bytes(
                "AccessControl: account 0x0000000000000000000000000000000000000006 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
        vm.prank(alice);
        vault.setExchangeProxyAddress(alice);

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        vault.setExchangeProxyAddress(address(0x00));
    }

    function testFuzz_AtomicDepositWithdraw(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        vault.deposit(amount, address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(weth.balanceOf(address(this)), preDepositBal);
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

    function test_AtomicDepositInvestRedeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e22); //max ~$280m flashloan
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        uint256 shares = vault.deposit(amount, address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);

        vault.depositIntoStrategy();

        // account for value loss if stETH worth less than ETH
        (, int256 price,,,) = vault.stEThToEthPriceFeed().latestRoundData();
        amount = amount.mulWadDown(uint256(price));

        // account for unrealized slippage loss
        amount = amount.mulWadDown(slippageTolerance);

        assertRelApproxEq(vault.totalAssets(), amount, 0.01e18);
        assertEq(vault.balanceOf(address(this)), shares);
        assertRelApproxEq(vault.convertToAssets(vault.balanceOf(address(this))), amount, 0.01e18);

        vault.redeem(shares, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertRelApproxEq(weth.balanceOf(address(this)), amount, 0.01e18);
    }

    function test_TwoDeposits_Invest_TwoRedeems(uint256 depositAmount1, uint256 depositAmount2) public {
        depositAmount1 = bound(depositAmount1, boundMinimum, 1e22);
        depositAmount2 = bound(depositAmount2, boundMinimum, 1e22);

        uint256 minDelta = 0.007e18;

        uint256 shares1 = depositToVault(address(this), depositAmount1);
        uint256 shares2 = depositToVault(alice, depositAmount2);

        vault.depositIntoStrategy();

        uint256 ltv = vault.targetLtv();

        uint256 expectedRedeem = vault.previewRedeem(shares1 / 2);
        vault.redeem(shares1 / 2, address(this), address(this));
        assertRelApproxEq(weth.balanceOf(address(this)), expectedRedeem, minDelta, "redeem1");

        assertRelApproxEq(vault.getLtv(), ltv, 0.013e18, "ltv");

        expectedRedeem = vault.previewRedeem(shares2 / 2);
        vm.prank(alice);
        vault.redeem(shares2 / 2, alice, alice);
        assertRelApproxEq(weth.balanceOf(alice), expectedRedeem, minDelta, "redeem2");

        assertRelApproxEq(vault.getLtv(), ltv, 0.01e18, "ltv");

        uint256 initBalance = weth.balanceOf(address(this));
        expectedRedeem = vault.previewRedeem(shares1 / 2);
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        assertRelApproxEq(weth.balanceOf(address(this)) - initBalance, expectedRedeem, minDelta, "redeem3");

        if (vault.getLtv() != 0) {
            assertRelApproxEq(vault.getLtv(), ltv, 0.01e18, "ltv");
        }

        initBalance = weth.balanceOf(alice);
        expectedRedeem = vault.previewRedeem(shares2 / 2);
        uint256 remainingShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(remainingShares, alice, alice);

        assertRelApproxEq(weth.balanceOf(alice) - initBalance, expectedRedeem, 0.01e18, "redeem4");
    }

    function test_LeverageUp(uint256 amount, uint256 newLtv) public {
        amount = bound(amount, boundMinimum, 1e20);
        depositToVault(address(this), amount);
        vault.depositIntoStrategy();
        newLtv = bound(newLtv, vault.getLtv() + 1e15, maxLtv - 0.001e18);
        console.log("vault.getLtv()", vault.getLtv());
        vault.changeLeverage(newLtv);
        console.log("vault.getLtv()", vault.getLtv());
        assertApproxEqRel(vault.getLtv(), newLtv, 0.01e18, "leverage change failed");
    }

    function test_LeverageDown(uint256 amount, uint256 newLtv) public {
        amount = bound(amount, boundMinimum, 1e20);
        depositToVault(address(this), amount);
        vault.depositIntoStrategy();
        newLtv = bound(newLtv, 0.01e18, vault.getLtv() - 0.01e18);
        console.log("vault.getLtv()", vault.getLtv());
        vault.changeLeverage(newLtv);
        console.log("vault.getLtv()", vault.getLtv());
        assertApproxEqRel(vault.getLtv(), newLtv, 0.01e18, "leverage change failed");
    }

    function test_BorrowOverMaxLtv_Fail(uint256 amount) public {
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

        console.log(stEthStakingInterest, 1.004e18);

        depositToVault(address(this), amount);

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
        depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _withdrawToVaultChecks(0.005e18);
    }

    function test_harvest_withdrawToVault(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        vault.harvest();

        _withdrawToVaultChecks(0.01e18);

        uint256 minimumExpectedApy = 0.07e18;

        assertGt(vault.totalProfit(), amount.mulWadDown(minimumExpectedApy), "atleast 5% APY");

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertGt(
            weth.balanceOf(address(this)) - amount,
            amount.mulWadDown(minimumExpectedApy),
            "atleast 5% APY after withdraw"
        );
    }

    function test_harvest_performanceFees(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        vault.harvest();
    }

    function test_DepositEth(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e21);
        vm.deal(address(this), amount);

        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(address(this).balance, amount);

        vault.deposit{value: amount}(address(this));

        assertEq(address(this).balance, 0, "eth not transferred from user");
        assertEq(vault.balanceOf(address(this)), amount, "shares not minted");
        assertEq(weth.balanceOf(address(vault)), amount, "weth not transferred to vault");
    }

    function depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _withdrawToVaultChecks(uint256 maxAssetsDelta) internal {
        uint256 assets = vault.totalAssets();

        assertEq(weth.balanceOf(address(vault)), 0);

        uint256 ltv = vault.getLtv();
        uint256 lev = vault.getLeverage();

        vault.withdrawToVault(assets / 2);

        // net ltv and leverage must not change after withdraw
        assertRelApproxEq(vault.getLtv(), ltv, 0.001e18);
        assertRelApproxEq(vault.getLeverage(), lev, 0.001e18);
        assertRelApproxEq(weth.balanceOf(address(vault)), assets / 2, maxAssetsDelta);

        // withdraw the remaining assets
        vault.withdrawToVault(assets / 2);

        uint256 dust = 100;
        assertLt(vault.totalDebt(), dust, "test_withdrawToVault totalDebt error");
        assertLt(vault.totalCollateralSupplied(), dust, "test_withdrawToVault totalCollateralSupplied error");
        assertRelApproxEq(weth.balanceOf(address(vault)), assets, maxAssetsDelta, "test_withdrawToVault asset balance");
    }

    function _simulate_stEthStakingInterest(uint256 timePeriod, uint256 stEthStakingInterest) internal {
        // fast forward time to simulate supply and borrow interests
        vm.warp(block.timestamp + timePeriod);
        // 5% increase in stETH contract eth balance to simulate profits from Lido staking
        uint256 prevBalance = stEth.getTotalPooledEther();
        vm.store(
            address(stEth),
            keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
            bytes32(prevBalance.mulWadDown(stEthStakingInterest))
        );
    }

    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta // An 18 decimal fixed point number, where 1e18 == 100%
    ) internal virtual {
        if (b == 0) return assertEq(a, b); // If the expected is 0, actual must be too.

        uint256 percentDelta = ((a > b ? a - b : b - a) * 1e18) / b;

        if (percentDelta > maxPercentDelta) {
            emit log("Error: a ~= b not satisfied [uint]");
            emit log_named_uint("    Expected", b);
            emit log_named_uint("      Actual", a);
            emit log_named_decimal_uint(" Max % Delta", maxPercentDelta, 18);
            emit log_named_decimal_uint("     % Delta", percentDelta, 18);
            fail();
        }
    }

    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta, // An 18 decimal fixed point number, where 1e18 == 100%,
        string memory message
    ) internal virtual {
        if (b == 0) return assertEq(a, b); // If the expected is 0, actual must be too.

        uint256 percentDelta = ((a > b ? a - b : b - a) * 1e18) / b;

        if (percentDelta > maxPercentDelta) {
            emit log("Error: a ~= b not satisfied [uint]");
            emit log_named_uint("    Expected", b);
            emit log_named_uint("      Actual", a);
            emit log_named_decimal_uint(" Max % Delta", maxPercentDelta, 18);
            emit log_named_decimal_uint("     % Delta", percentDelta, 18);
            emit log(message);
            fail();
        }
    }

    receive() external payable {}
}
