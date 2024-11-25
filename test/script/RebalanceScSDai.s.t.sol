// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {scSDAI} from "src/steth/scSDAI.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";
import {SparkScSDaiAdapter} from "src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";
import {SDaiWethPriceConverter} from "src/steth/priceConverter/SDaiWethPriceConverter.sol";

import {RebalanceScSDai} from "script/v2/keeper-actions/RebalanceScSDai.s.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "script/base/scCrossAssetYieldVaultRebalanceScript.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";

contract RebalanceScSDaiTest is Test {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 mainnetFork;

    scSDAI vault;
    SparkScSDaiAdapter spark;
    SDaiWethPriceConverter priceConverter;
    RebalanceScSDaiTestHarness script;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21031368);

        vault = scSDAI(MainnetAddresses.SCSDAI);
        spark = SparkScSDaiAdapter(MainnetAddresses.SCSDAI_SPARK_ADAPTER);
        priceConverter = SDaiWethPriceConverter(MainnetAddresses.SDAI_WETH_PRICE_CONVERTER);

        script = new RebalanceScSDaiTestHarness(vault);
    }

    function test_run_initialRebalance() public {
        deal(C.SDAI, address(vault), 10000e18);

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral() + script.assetBalance() - expectedFloat;
        uint256 expectedDebt = priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.sparkTargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "sDai balance");
    }

    function test_run_rebalanceWithProfit() public {
        script.run();

        _assertInitialState();

        _simulate100PctProfit();

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral().mulWadDown(1e18 + script.sparkTargetLtv());
        uint256 expectedDebt = priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.sparkTargetLtv());

        script = new RebalanceScSDaiTestHarness(vault);
        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.8e18, "sDai balance");
    }

    function test_run_canDeleverage() public {
        script.run();

        _assertInitialState();

        script = new RebalanceScSDaiTestHarness(vault);
        script.setSparkTargetLtv(0.2e18);

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral();
        uint256 expectedDebt = priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.sparkTargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.8e18, "sDai balance");
    }

    function _assertInitialState() internal {
        assertTrue(script.targetTokensInvested() > 0, "initial weth invested 0");
        assertTrue(vault.totalDebt() > 0, "initial total debt 0");
        assertTrue(vault.totalCollateral() > 0, "initial  total collateral 0");
        assertTrue(script.assetBalance() > 0, "initial sDai balance 0");
    }

    function _simulate100PctProfit() internal {
        WETH weth = WETH(payable(C.WETH));

        console2.log("weth balance before", weth.balanceOf(address(script.targetVault())));
        console2.log("total assets before", script.targetVault().totalAssets());

        // simulate 100% profit by dealing more WETH to scWETH vault
        deal(
            address(weth),
            address(script.targetVault()),
            script.targetVault().totalAssets() + weth.balanceOf(address(script.targetVault()))
        );

        console2.log("weth balance after", weth.balanceOf(address(script.targetVault())));
        console2.log("total assets after", script.targetVault().totalAssets());
    }
}

contract RebalanceScSDaiTestHarness is RebalanceScSDai {
    constructor(scSDAI _vault) {
        vault = _vault;
    }

    function _initEnv() internal override {
        // TODO: WRONG KEEPER ADDRESS???
        keeper = 0x3Ab6EBDBf08e1954e69F6859AdB2DA5236D2e838;
    }

    function _getVaultAddress() internal view override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vault);
    }

    function setSparkTargetLtv(uint256 _newTargetLtv) public {
        sparkTargetLtv = _newTargetLtv;
    }

    function setSparkInvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        sparkInvestableAmountPercent = _newInvestableAmountPercent;
    }
}
