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

import {ERC20} from "solmate/tokens/ERC20.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    // dummy users
    address constant alice = address(0x06);
    uint256 boundMinimum = 1e10; // below this amount, aave doesn't count it as collateral

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

        vault = new Vault(address(this));

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

    function testEMode() public {
        assertEq(aavePool.getUserEMode(address(vault)), vault.EMODE_ID(), "E mode not same");
    }

    function testAtomicDepositWithdraw(uint256 amount) public {
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

    function testFailDepositWithInsufficientApproval(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount, address(this));
    }

    function testFailWithdrawWithInsufficientBalance(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithInsufficientBalance(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.redeem(amount, address(this), address(this));
    }

    function testFailWithdrawWithNoBalance(uint256 amount) public {
        if (amount == 0) amount = 1;
        vault.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithNoBalance(uint256 amount) public {
        vault.redeem(amount, address(this), address(this));
    }

    function testFailDepositWithNoApproval(uint256 amount) public {
        vault.deposit(amount, address(this));
    }

    function testAtomicDepositInvestRedeem(uint256 amount) public {
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

        assertApproxEqRel(vault.totalAssets(), amount, 0.01e18);
        assertEq(vault.balanceOf(address(this)), shares);
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(address(this))), amount, 0.01e18);

        vault.redeem(shares, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertApproxEqRel(weth.balanceOf(address(this)), amount, 0.01e18);
    }

    function testTwoDepositsInvestTwoRedeems(uint256 depositAmount1, uint256 depositAmount2) public {
        depositAmount1 = bound(depositAmount1, boundMinimum, 1e22);
        depositAmount2 = bound(depositAmount2, boundMinimum, 1e22);

        uint256 minDelta = 0.007e18;

        uint256 shares1 = depositToVault(address(this), depositAmount1);
        uint256 shares2 = depositToVault(alice, depositAmount2);

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

        if (vault.getLtv() != 0) {
            assertApproxEqRel(vault.getLtv(), ltv, 0.01e18, "ltv");
        }

        initBalance = weth.balanceOf(alice);
        expectedRedeem = vault.previewRedeem(shares2 / 2);
        uint256 remainingShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(remainingShares, alice, alice);

        // if (vault.getLtv() != 0) {
        //     assertApproxEqRel(vault.getLtv(), ltv, 0.01e18, "ltv");
        // }

        assertApproxEqRel(weth.balanceOf(alice) - initBalance, expectedRedeem, 0.01e18, "redeem4");
        // assertGe(weth.balanceOf(alice) - initBalance, expectedRedeem);
    }

    function testWithdrawToVault(uint256 amount) public {
        amount = bound(amount, boundMinimum, 10000 ether);
        depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        uint256 assets = vault.totalAssets();

        assertEq(weth.balanceOf(address(vault)), 0);

        uint256 ltv = vault.getLtv();
        uint256 lev = vault.getLeverage();

        vault.withdrawToVault(assets / 2);

        // net ltv and leverage must not change after withdraw
        assertApproxEqRel(vault.getLtv(), ltv, 0.001e18);
        assertApproxEqRel(vault.getLeverage(), lev, 0.001e18);
        assertApproxEqRel(weth.balanceOf(address(vault)), assets / 2, 0.001e18);
    }

    function testLeverageUp(uint256 amount, uint256 newLtv) public {
        amount = bound(amount, boundMinimum, 1e20);
        depositToVault(address(this), amount);
        vault.depositIntoStrategy();
        newLtv = bound(newLtv, vault.getLtv() + 1e15, maxLtv - 0.001e18);
        console.log("vault.getLtv()", vault.getLtv());
        vault.changeLeverage(newLtv);
        console.log("vault.getLtv()", vault.getLtv());
        assertApproxEqRel(vault.getLtv(), newLtv, 0.01e18, "leverage change failed");
    }

    function testLeverageDown(uint256 amount, uint256 newLtv) public {
        amount = bound(amount, boundMinimum, 1e20);
        depositToVault(address(this), amount);
        vault.depositIntoStrategy();
        newLtv = bound(newLtv, 0.01e18, vault.getLtv() - 0.01e18);
        console.log("vault.getLtv()", vault.getLtv());
        vault.changeLeverage(newLtv);
        console.log("vault.getLtv()", vault.getLtv());
        assertApproxEqRel(vault.getLtv(), newLtv, 0.01e18, "leverage change failed");
    }

    function testBorrowOverMaxLtvFail(uint256 amount) public {
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

    function testHarvest(uint256 amount, uint64 tP) public {
        amount = bound(amount, boundMinimum, 1e21);
        // simulate wstETH supply interest to EULER
        uint256 timePeriod = bound(tP, 260 days, 365 days);
        uint256 annualPeriod = 365 days;
        uint256 stEthStakingApy = 0.071e18;
        uint256 stEthStakingInterest = 1e18 + stEthStakingApy.mulDivDown(timePeriod, annualPeriod);

        console.log(stEthStakingInterest, 1.004e18);

        depositToVault(address(this), amount);

        vault.depositIntoStrategy();

        // fast forward time to simulate supply and borrow interests
        vm.warp(block.timestamp + timePeriod);
        // 5% increase in stETH contract eth balance to simulate profits from Lido staking
        uint256 prevBalance = stEth.getTotalPooledEther();
        vm.store(
            address(stEth),
            keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
            bytes32(prevBalance.mulWadDown(stEthStakingInterest))
        );

        assertEq(vault.totalProfit(), 0);

        vault.harvest();

        uint256 minimumExpectedApy = 0.05e18;

        assertGt(
            vault.totalProfit(),
            amount.mulWadDown(minimumExpectedApy.mulDivDown(timePeriod, annualPeriod)),
            "atleast 5% APY"
        );

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertGt(
            weth.balanceOf(address(this)) - amount,
            amount.mulWadDown(minimumExpectedApy.mulDivDown(timePeriod, annualPeriod)),
            "atleast 5% APY after withdraw"
        );
    }

    function testDepositEth(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e21);
        vm.deal(address(this), amount);

        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(address(this).balance, amount);

        vault.deposit{value: amount}(address(this));

        assertEq(address(this).balance, 0, "eth not transferred from user");
        assertEq(vault.balanceOf(address(this)), amount, "shares not minted");
        assertEq(weth.balanceOf(address(vault)), amount, "weth not transferred to vault");
    }

    function depositToVault(address user, uint256 amount) public returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    receive() external payable {}
}
