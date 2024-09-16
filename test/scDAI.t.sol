// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {SparkScSDaiAdapter} from "../src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";
import {scSDAI} from "../src/steth/scSDAI.sol";
import {scDAI} from "../src/steth/scDAI.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {PriceConverter} from "../src/steth/priceConverter/PriceConverter.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";
import {ISinglePairPriceConverter} from "../src/steth/priceConverter/IPriceConverter.sol";
import {SDaiWethPriceConverter} from "../src/steth/priceConverter/SDaiWethPriceConverter.sol";
import {SDaiWethSwapper} from "../src/steth/swapper/SDaiWethSwapper.sol";

contract scDAITest is Test {
    using SafeTransferLib for ERC20;
    using Address for address;
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant bob = address(0x07);

    WETH weth;
    ERC4626 sDai;
    ERC20 dai;

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scSDAI scsDAI;
    scDAI vault;

    SparkScSDaiAdapter spark;
    SDaiWethSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19832667);

        sDai = ERC4626(C.SDAI);
        dai = ERC20(C.DAI);
        weth = WETH(payable(C.WETH));
        spark = new SparkScSDaiAdapter();

        _deployAndSetUpScsDai();

        vault = new scDAI(scsDAI);
    }

    function test_constructor() public {
        vault = new scDAI(scsDAI);

        assertEq(address(vault.scsDai()), address(scsDAI), "scsDAI not updated");
        assertEq(dai.allowance(address(vault), C.SDAI), type(uint256).max, "dai allowance error");
        assertEq(sDai.allowance(address(vault), address(scsDAI)), type(uint256).max, "sDai allowance error");
    }

    function test_deposit(uint256 amount) public {
        amount = bound(amount, 1e15, 100000000e18);
        deal(address(dai), address(this), amount);

        dai.approve(address(vault), amount);

        vault.deposit(amount, address(this));

        assertEq(vault.balanceOf(address(this)), amount, "scDAI shares");
        assertEq(scsDAI.balanceOf(address(this)), 0, "scsDAI shares to user");
        assertEq(scsDAI.balanceOf(address(vault)), sDai.convertToShares(amount), "scsDAI shares to scDAI");

        assertApproxEqRel(vault.totalAssets(), amount, 1e10, "totalAssets");
    }

    function test_withdraw_redeem(uint256 amount) public {
        amount = bound(amount, 1e10, 100000000e18);
        deal(address(dai), address(this), amount);

        dai.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        uint256 withdrawAmount = amount / 2;

        vault.withdraw(withdrawAmount, address(this), address(this));

        assertApproxEqRel(dai.balanceOf(address(this)), withdrawAmount, 1e10, "dai after withdraw");
        assertApproxEqRel(vault.totalAssets(), amount - withdrawAmount, 1e10, "totalAssets");

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertApproxEqRel(dai.balanceOf(address(this)), amount, 1e10, "dai after full redeem");
        assertEq(vault.balanceOf(address(this)), 0, "scDAI shares not zero");
        assertApproxEqRel(vault.totalAssets(), 1, 1e10, "totalAssets after redeem");
    }

    function test_withdraw_failsIfCallerIsNotOwner() public {
        uint256 amount = 1000e18;
        _deposit(amount, alice);

        vm.expectRevert();

        vm.prank(bob);
        vault.withdraw(amount / 2, address(this), alice);
    }

    function test_wihdraw_failsIfWithdrawingMoreThanBalance() public {
        uint256 amount = 1000e18;
        _deposit(amount, alice);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdraw(amount + 1, alice, alice);
    }

    function test_withdraw_failsIfCallerIsNotApproved() public {
        uint256 amount = 1000e18;
        _deposit(amount, alice);

        assertEq(vault.allowance(alice, bob), 0, "allowance not zero");

        uint256 withdrawAmount = amount / 2;

        vm.expectRevert();
        vm.prank(bob);
        vault.withdraw(withdrawAmount, bob, alice);
    }

    function test_withdraw_worksIfCallerIsApproved() public {
        uint256 amount = 1000e18;
        uint256 shares = _deposit(amount, alice);

        vm.prank(alice);
        vault.approve(bob, shares / 2);

        assertEq(vault.allowance(alice, bob), shares / 2, "allowance not set");

        uint256 withdrawAmount = vault.convertToAssets(shares / 2);

        vm.prank(bob);
        vault.withdraw(withdrawAmount, bob, alice);

        assertEq(vault.allowance(alice, bob), 0, "allowance not reduced to 0");
        assertApproxEqAbs(dai.balanceOf(bob), withdrawAmount, 1, "withdrawn amount not transferred to bob");
    }

    function test_redeem_failsIfCallerIsNotOwner() public {
        uint256 amount = 1000e18;
        uint256 shares = _deposit(amount, alice);

        vm.expectRevert();

        vm.prank(bob);
        vault.redeem(shares, address(this), alice);
    }

    function test_redeem_failsIfWithdrawingMoreThanBalance() public {
        uint256 amount = 1000e18;
        uint256 shares = _deposit(amount, alice);

        vm.expectRevert();
        vm.prank(alice);
        vault.redeem(shares + 1, alice, alice);
    }

    function test_redeem_failsIfCallerIsNotApproved() public {
        uint256 amount = 1000e18;
        uint256 shares = _deposit(amount, alice);

        assertEq(vault.allowance(alice, bob), 0, "allowance not zero");

        uint256 redeemAmount = shares / 2;

        vm.expectRevert();
        vm.prank(bob);
        vault.redeem(redeemAmount, bob, alice);
    }

    function test_redeem_worksIfCallerIsApproved() public {
        uint256 amount = 1000e18;
        uint256 shares = _deposit(amount, alice);

        vm.prank(alice);
        vault.approve(bob, shares / 2);

        assertEq(vault.allowance(alice, bob), shares / 2, "allowance not set");

        uint256 redeemAmount = shares / 2;

        vm.prank(bob);
        vault.redeem(redeemAmount, bob, alice);

        assertEq(vault.allowance(alice, bob), 0, "allowance not reduced to 0");
    }

    function test_redeem_roundDown() public {
        uint256 amount = 2;
        uint256 shares = _deposit(amount, alice);

        assertEq(shares, 2, "shares not 2");

        uint256 redeemAmount = 1;

        vm.prank(alice);
        vm.expectRevert("ZERO_ASSETS");
        vault.redeem(redeemAmount, bob, alice);
    }

    function _deployAndSetUpScsDai() internal {
        priceConverter = new SDaiWethPriceConverter();
        swapper = new SDaiWethSwapper();

        scsDAI = new scSDAI(address(this), keeper, wethVault, priceConverter, swapper);

        scsDAI.addAdapter(spark);

        // set vault eth balance to zero
        vm.deal(address(scsDAI), 0);
        // set float percentage to 0 for most tests
        scsDAI.setFloatPercentage(0);
        // assign keeper role to deployer
        scsDAI.grantRole(scsDAI.KEEPER_ROLE(), address(this));
    }

    function _deposit(uint256 amount, address owner) internal returns (uint256 shares) {
        deal(address(dai), owner, amount);

        vm.startPrank(owner);
        dai.approve(address(vault), amount);

        shares = vault.deposit(amount, owner);

        vm.stopPrank();
    }
}
