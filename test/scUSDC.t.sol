// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scUSDC as Vault} from "../src/steth/scUSDC.sol";
import {scWETH as WethVault} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {IEulerDToken} from "../src/interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../src/interfaces/euler/IEulerEToken.sol";
import {IMarkets} from "../src/interfaces/euler/IMarkets.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {scWETH} from "../src/steth/scWETH.sol";

contract scUSDCTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 0.7735e18;
    uint256 constant slippageTolerance = 0.999e18;
    uint256 constant flashLoanLtv = 0.5e18;

    // dummy users
    address constant alice = address(0x06);

    Vault vault;
    WethVault wethVault;
    uint256 initAmount = 100e18;

    address EULER;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    IEulerEToken eTokenWstEth;
    IEulerDToken dTokenWeth;
    IMarkets markets;
    ICurvePool curvePool;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16643381);

        wethVault = new WethVault(
            address(this),
            ethWstEthMaxLtv,
            flashLoanLtv,
            slippageTolerance
        );

        vault = new Vault(
            address(this),
            ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
            wethVault
        );

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        // weth = WETH(payable(vault.WETH()));
        // EULER = vault.EULER();

        // wstEth.approve(EULER, type(uint256).max);
        // weth.approve(EULER, type(uint256).max);
        // markets.enterMarket(0, address(wstEth));
    }

    function testAtomicDepositWithdraw() public {
        // vault.depositIntoStrategy();
        deal(address(vault.USDC()), alice, 10000e6);

        vm.startPrank(alice);
        ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).approve(
            address(vault),
            type(uint256).max
        );
        vault.deposit(10000e6, alice);
        vm.stopPrank();

        vault.depositIntoStrategy();

        console2.log("totalAssets", vault.totalAssets());
        console2.log("alice balance", vault.balanceOf(alice));
        console2.log(
            "alices usdc assets",
            vault.convertToAssets(vault.balanceOf(alice))
        );

        vm.startPrank(alice);
        vault.withdraw(5000e6, alice, alice);
    }

    function testTotalAssets() public {
        deal(address(vault.USDC()), address(vault), 10000e6);
        // assertEq(ERC20(vault.USDC()).balanceOf(alice), 10000e6);
        // vault.totalAssets();
        vault.depositIntoStrategy();

        console2.log("totalAssets", vault.totalAssets());
    }
}
