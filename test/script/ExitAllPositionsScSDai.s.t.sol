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
import {scSDAI} from "src/steth/scSDAI.sol";
import {PriceConverter} from "src/steth/priceConverter/PriceConverter.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {ExitAllPositionsScSDai} from "script/v2/keeper-actions/ExitAllPositionsScSDai.s.sol";
import {SparkScSDaiAdapter} from "src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";
import {SDaiWethPriceConverter} from "src/steth/priceConverter/SDaiWethPriceConverter.sol";

contract ExitAllPositionsScSDaiTest is Test {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    scSDAI vault;
    SparkScSDaiAdapter spark;
    SDaiWethPriceConverter priceConverter;
    ExitAllPositionsScSDai script;

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21031368);

        vault = scSDAI(MainnetAddresses.SCSDAI);
        spark = SparkScSDaiAdapter(vault.getAdapter(1));
        priceConverter = SDaiWethPriceConverter(address(vault.priceConverter()));

        script = new ExitAllPositionsScSDaiTestHarness(vault);
    }

    function test_run_exitsAllPositions() public {
        assertTrue(vault.asset().balanceOf(address(vault)) > 0, "sDai balance");
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
}

contract ExitAllPositionsScSDaiTestHarness is ExitAllPositionsScSDai {
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
