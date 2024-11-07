// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";
import {scUSDT} from "src/steth/scUSDT.sol";
import {PriceConverter} from "src/steth/priceConverter/PriceConverter.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {ExitAllPositionsScUsdt} from "script/v2/keeper-actions/ExitAllPositionsScUsdt.s.sol";
import {AaveV3ScUsdtAdapter} from "src/steth/scUsdt-adapters/AaveV3ScUsdtAdapter.sol";
import {UsdtWethPriceConverter} from "src/steth/priceConverter/UsdtWethPriceConverter.sol";
import {UsdtWethSwapper} from "src/steth/swapper/UsdtWethSwapper.sol";

contract ExitAllPositionsScUsdtTest is Test {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    scUSDT vault;
    UsdtWethPriceConverter priceConverter;
    ExitAllPositionsScUsdt script;

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21031368);

        priceConverter = UsdtWethPriceConverter(MainnetAddresses.USDT_WETH_PRICE_CONVERTER);
        vault = scUSDT(MainnetAddresses.SCUSDT);

        script = new ExitAllPositionsScUsdtTestHarness(vault);
    }

    function test_run_exitsAllPositions() public {
        assertTrue(vault.asset().balanceOf(address(vault)) > 0, "usdt balance");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.totalDebt() > 0, "total debt");

        // add 20% profit
        ERC20 targetAsset = vault.targetVault().asset();
        uint256 targetVaultBalance = targetAsset.balanceOf(address(vault.targetVault()));
        uint256 targetVaultTotalAssets = vault.targetVault().totalAssets();
        deal(
            address(targetAsset),
            address(vault.targetVault()),
            targetVaultBalance + targetVaultTotalAssets.mulWadDown(0.2e18)
        );

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 maxLossPercent = script.maxAceeptableLossPercent();

        // exit
        script.run();

        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore, maxLossPercent, "total assets");
    }

    function _rebalance(uint256 investAmount, uint256 debtAmount) internal {
        bytes[] memory callData = new bytes[](2);

        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, 1, investAmount);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, 1, debtAmount);

        vm.prank(0x3Ab6EBDBf08e1954e69F6859AdB2DA5236D2e838);
        vault.rebalance(callData);
    }
}

contract ExitAllPositionsScUsdtTestHarness is ExitAllPositionsScUsdt {
    constructor(scCrossAssetYieldVault _vault) {
        vault = _vault;
    }

    function _initEnv() internal override {
        // TODO: WRONG KEEPER ADDRESS???
        keeper = 0x3Ab6EBDBf08e1954e69F6859AdB2DA5236D2e838;
    }

    function _getVaultAddress() internal view override returns (scCrossAssetYieldVault) {
        return vault;
    }
}
