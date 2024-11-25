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
import {scWBTC} from "src/steth/scWBTC.sol";
import {AaveV3ScWbtcAdapter} from "src/steth/scWbtc-adapters/AaveV3ScWbtcAdapter.sol";
import {WbtcWethPriceConverter} from "src/steth/priceConverter/WbtcWethPriceConverter.sol";
import {WbtcWethSwapper} from "src/steth/swapper/WbtcWethSwapper.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";

import {RebalanceScWbtc} from "script/v2/keeper-actions/RebalanceScWbtc.s.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";

contract RebalanceScWbtcTest is Test {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    scWBTC vault;
    AaveV3ScWbtcAdapter aaveV3;
    WbtcWethPriceConverter priceConverter;
    RebalanceScWbtcTestHarness script;

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21209561);

        // TODO: use deployed addresses here instead of creating new instances when deployed on mainnet
        aaveV3 = new AaveV3ScWbtcAdapter();
        priceConverter = new WbtcWethPriceConverter();
        WbtcWethSwapper swapper = new WbtcWethSwapper();

        vault = new scWBTC(
            address(this), MainnetAddresses.KEEPER, ERC4626(MainnetAddresses.SCWETHV2), priceConverter, swapper
        );

        vault.addAdapter(aaveV3);

        // make an initial deposit
        uint256 depositAmount = 1e8; // 1 WBTC
        deal(C.WBTC, address(this), depositAmount);
        ERC20(C.WBTC).safeApprove(address(vault), depositAmount);
        vault.deposit(depositAmount, address(this));

        script = new RebalanceScWbtcTestHarness(vault);
    }

    function test_run_initialRebalance() public {
        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(script.totalDebt(), 0, "total debt");
        assertEq(script.totalCollateral(), 0, "total collateral");
        assertTrue(script.assetBalance() > 0, "wbtc balance");

        uint256 expectedFloat = script.assetBalance().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.assetBalance() - expectedFloat;
        uint256 expectedDebt =
            priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.aaveV3TargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "wbtc balance");
    }

    function test_run_rebalanceWithProfit() public {
        script.run();

        _assertInitialState();

        _simulate100PctProfit();

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral().mulWadDown(1e18 + script.aaveV3TargetLtv());
        uint256 expectedDebt =
            priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.aaveV3TargetLtv());

        script = new RebalanceScWbtcTestHarness(vault);
        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.7e18, "wbtc balance");
    }

    function test_run_canDeleverage() public {
        script.run();

        _assertInitialState();

        script = new RebalanceScWbtcTestHarness(vault);
        script.setAaveV3TargetLtv(0.2e18);

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral();
        uint256 expectedDebt =
            priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.aaveV3TargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.4e18, "wbtc balance");
    }

    function _assertInitialState() internal {
        assertTrue(script.targetTokensInvested() > 0, "initial weth invested 0");
        assertTrue(vault.totalDebt() > 0, "initial total debt 0");
        assertTrue(vault.totalCollateral() > 0, "initial  total collateral 0");
        assertTrue(script.assetBalance() > 0, "initial wbtc balance 0");
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

contract RebalanceScWbtcTestHarness is RebalanceScWbtc {
    constructor(scWBTC _vault) {
        vault = _vault;
    }

    function _getVaultAddress() internal view override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vault);
    }

    function setAaveV3TargetLtv(uint256 _newTargetLtv) public {
        aaveV3TargetLtv = _newTargetLtv;
    }

    function setAaveV3InvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        aaveV3InvestableAmountPercent = _newInvestableAmountPercent;
    }
}
