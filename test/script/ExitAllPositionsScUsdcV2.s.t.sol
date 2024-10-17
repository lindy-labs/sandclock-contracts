// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scCrossAssetYieldVault} from "../../src/steth/scCrossAssetYieldVault.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";
import {ExitAllPositionsScUsdcV2} from "../../script/v2/keeper-actions/ExitAllPositionsScUsdcV2.s.sol";

contract ExitAllPositionsScUsdcV2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    scUSDCv2 vault;
    PriceConverter priceConverter;
    ExitAllPositionsScUsdcV2 script;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18488739);

        vault = scUSDCv2(MainnetAddresses.SCUSDCV2);
        priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);

        script = new ExitAllPositionsScUsdcV2();
    }

    function test_run_exitsAllPositions() public {
        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertTrue(vault.asset().balanceOf(address(vault)) > 0, "usdc balance");

        // deposit
        deal(address(vault.asset()), address(this), 1000e6);
        vault.asset().approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));

        // rebalance to create some debt & collateral positions
        uint256 investAmount = 900e6;
        uint256 debtAmount = priceConverter.usdcToEth(investAmount).mulWadDown(0.7e18);

        _rebalance(investAmount, debtAmount);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 maxLossPercent = script.maxAceeptableLossPercent();

        assertApproxEqAbs(script.targetTokensInvested(), debtAmount, 1, "weth invested");
        assertApproxEqAbs(vault.totalDebt(), debtAmount, 1, "total debt");
        assertApproxEqAbs(vault.totalCollateral(), investAmount, 1, "total collateral");

        // exit
        script.run();

        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore, maxLossPercent, "total assets");
    }

    function _rebalance(uint256 investAmount, uint256 debtAmount) internal {
        bytes[] memory callData = new bytes[](4);

        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, 1, investAmount / 2);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, 4, investAmount / 2);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, 1, debtAmount / 2);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, 4, debtAmount / 2);

        vm.prank(MainnetAddresses.KEEPER);
        vault.rebalance(callData);
    }
}
