// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {AaveV3ScUsdtAdapter} from "../src/steth/scUsdt-adapters/AaveV3ScUsdtAdapter.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {PriceConverter} from "../src/steth/priceConverter/PriceConverter.sol";
import {ISinglePairPriceConverter} from "../src/steth/priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "../src/steth/swapper/ISinglePairSwapper.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";
import {scUSDS} from "../src/steth/scUSDS.sol";
import {IDaiUsds} from "../src/interfaces/sky/IDaiUsds.sol";
import {scSDAI} from "../src/steth/scSDAI.sol";
import {scDAI} from "../src/steth/scDAI.sol";
import {SDaiWethSwapper} from "../src/steth/swapper/SDaiWethSwapper.sol";
import {SDaiWethPriceConverter} from "../src/steth/priceConverter/SDaiWethPriceConverter.sol";
import {SparkScSDaiAdapter} from "../src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";

contract scUSDSTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant bob = address(0x07);

    WETH weth;
    ERC20 usds;
    ERC20 dai = ERC20(C.DAI);
    ERC4626 public constant sDai = ERC4626(C.SDAI);

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scSDAI scsDAI;
    scUSDS vault;

    AaveV3ScUsdtAdapter aaveV3Adapter;
    ISinglePairSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    uint256 pps;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20825479);

        usds = ERC20(C.USDS);
        weth = WETH(payable(C.WETH));

        pps = wethVault.totalAssets().divWadDown(wethVault.totalSupply());

        _deployAndSetUpScSDai();

        vault = new scUSDS(ERC4626(address(scsDAI)));
    }

    function test_constructor() public {
        vault = new scUSDS(ERC4626(address(scsDAI)));

        assertEq(
            dai.allowance(address(vault), C.DAI_USDS_CONVERTER), type(uint256).max, "dai allowance to daiusds converter"
        );
        assertEq(sDai.allowance(address(vault), address(scsDAI)), type(uint256).max, "dai allowance to scDAI");
        assertEq(dai.allowance(address(vault), C.SDAI), type(uint256).max, "dai allowance to sDai");
        assertEq(usds.allowance(address(vault), C.DAI_USDS_CONVERTER), type(uint256).max, "weth allowance");
    }

    function test_DaiUsdsConverter() public {
        IDaiUsds daiUsdsConverter = IDaiUsds(C.DAI_USDS_CONVERTER);

        uint256 daiAmount = 100e18;
        deal(address(dai), address(this), daiAmount);

        assertEq(usds.balanceOf(address(this)), 0, "initial usds amount");
        assertEq(dai.balanceOf(address(this)), daiAmount, "initial dai amount");

        dai.safeApprove(address(daiUsdsConverter), daiAmount);

        daiUsdsConverter.daiToUsds(address(this), daiAmount);

        assertEq(usds.balanceOf(address(this)), daiAmount, "usds transfer error");
        assertEq(dai.balanceOf(address(this)), 0, "dai transfer error");

        // transfer dai to usds
        usds.safeApprove(address(daiUsdsConverter), daiAmount);
        daiUsdsConverter.usdsToDai(address(this), daiAmount);

        assertEq(usds.balanceOf(address(this)), 0, "usds transfer error 2");
        assertEq(dai.balanceOf(address(this)), daiAmount, "dai transfer error 2");
    }

    function test_deposit(uint256 amount) public {
        amount = bound(amount, 1e10, 100000000e18);
        deal(address(usds), address(this), amount);

        usds.approve(address(vault), amount);

        vault.deposit(amount, address(this));

        assertEq(vault.balanceOf(address(this)), amount, "scUSDS shares");
        assertEq(scsDAI.balanceOf(address(this)), 0, "scsDAI shares to user");
        assertEq(scsDAI.balanceOf(address(vault)), sDai.convertToShares(amount), "amount deposited in scsDAI");

        assertApproxEqRel(vault.totalAssets(), amount, 1e10, "totalAssets");
    }

    function test_withdraw_redeem() public {
        uint256 amount = 10_000e18;
        _deposit(amount, address(this));

        uint256 withdrawAmount = amount / 2;

        vault.withdraw(withdrawAmount, address(this), address(this));

        assertApproxEqRel(usds.balanceOf(address(this)), withdrawAmount, 1e10, "usds after withdraw");
        assertApproxEqRel(vault.totalAssets(), amount - withdrawAmount, 1e10, "totalAssets");

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertApproxEqRel(usds.balanceOf(address(this)), amount, 1e10, "usds after full redeem");
        assertEq(vault.balanceOf(address(this)), 0, "scUSDS shares not zero");
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
    }

    function test_withdraw_whenInProfit() public {
        uint256 amount = 10_000e18;
        uint256 shares = _deposit(amount, address(this));

        uint256 profit = 200e18;

        deal(C.SDAI, address(scsDAI), amount + profit);

        vault.redeem(shares, address(this), address(this));

        assertGt(usds.balanceOf(address(this)), amount + profit, "profits not withdrawn");
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

    /////////////////////////////// INTERNAL METHODS /////////////////////////////////////////////////

    function _deployAndSetUpScSDai() internal {
        priceConverter = new SDaiWethPriceConverter();
        swapper = new SDaiWethSwapper();

        scsDAI = new scSDAI(address(this), keeper, wethVault, priceConverter, swapper);

        scsDAI.addAdapter(new SparkScSDaiAdapter());

        // set vault eth balance to zero
        vm.deal(address(scsDAI), 0);
        // set float percentage to 0 for most tests
        scsDAI.setFloatPercentage(0);
        // assign keeper role to deployer
        scsDAI.grantRole(scsDAI.KEEPER_ROLE(), address(this));
    }

    function _deposit(uint256 amount, address owner) internal returns (uint256 shares) {
        deal(address(usds), owner, amount);

        vm.startPrank(owner);
        usds.approve(address(vault), amount);

        shares = vault.deposit(amount, owner);

        vm.stopPrank();
    }
}
