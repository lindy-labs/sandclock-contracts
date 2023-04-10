// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {CErc20} from "../src/interfaces/compound/CErc20.sol";
import {CEther} from "../src/interfaces/compound/CEther.sol";
import {Comptroller} from "../src/interfaces/compound/Comptroller.sol";

contract CompoundExample is Test {
    using FixedPointMathLib for uint256;

    function test_compound() public {
        uint256 forkId = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(forkId);
        vm.rollFork(16643381);
        ERC20 usdc = ERC20(C.USDC);

        uint256 deposit = 10_000e6;
        deal(address(usdc), address(this), deposit);

        CErc20 cUSDC = CErc20(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
        usdc.approve(address(cUSDC), type(uint256).max);
        uint256 mintResult = cUSDC.mint(deposit); // 0 = success
        console2.log("mintResult", mintResult);
        assertEq(mintResult, 0, "mintResult");

        Comptroller comptroller = Comptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);

        CEther cETH = CEther(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(cETH);
        cTokens[1] = address(cUSDC);
        uint256[] memory enterResults = comptroller.enterMarkets(cTokens);
        console2.log("enterResults", enterResults.length);
        assertEq(enterResults.length, 2, "no result for entering the market");
        console2.log("enterResults[0]", enterResults[0]);
        console2.log("enterResults[1]", enterResults[1]);
        assertEq(enterResults[0], 0, "did not enter the cETH market");
        assertEq(enterResults[1], 0, "did not enter the cUSDC market");

        console2.log("cUsdcBalance before", cUSDC.balanceOf(address(this)));
        vm.roll(block.number + 1000);
        uint256 cUsdcBalance = cUSDC.balanceOf(address(this));
        console2.log("cUsdcBalance", cUsdcBalance);

        uint256 cUsdcBalanceOfUnderlying = cUSDC.balanceOfUnderlying(address(this));
        console2.log("cUsdcBalanceOfUnderlying", cUsdcBalanceOfUnderlying);

        uint256 borrowAmount = 1e18;
        uint256 balanceBefore = address(this).balance;
        uint256 borrowResult = cETH.borrow(borrowAmount);
        console2.log("borrowResult", borrowResult);
        assertEq(borrowResult, 0, "borrow failed");
        console2.log("borrowed eth", address(this).balance - balanceBefore);
        assertEq(cETH.borrowBalanceCurrent(address(this)), borrowAmount, "borrow amount not correct");

        cETH.repayBorrow{value: borrowAmount}();
        console2.log("balance after debt is repayed", address(this).balance - balanceBefore);

        uint256 usdcCollateralFactor = comptroller.markets(address(cUSDC)).collateralFactorMantissa;
        console2.log("usdcCollateralFactor", usdcCollateralFactor); // 855000000000000000

        uint256 usdcSupplyRatePerBlock = cUSDC.supplyRatePerBlock();
        uint256 blocksPerYear = 2102400; // estimated as 2102400 assuming 13.2 seconds per block
        uint256 usdcSupplyAPR = usdcSupplyRatePerBlock * blocksPerYear;
        console2.log("usdcSupplyAPR", usdcSupplyAPR); // 0.015080590556323200 ~ 1.5%
    }

    receive() external payable {
        console2.log("received", msg.value);
    }
}
