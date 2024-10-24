// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {RebalanceScUsdcV2} from "../../script/v2/keeper-actions/RebalanceScUsdcV2.s.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "../../script/base/scCrossAssetYieldVaultRebalanceScript.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";
import {Constants} from "../../src/lib/Constants.sol";

contract RebalanceScUsdcV2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    scUSDCv2 vault;
    AaveV3ScUsdcAdapter aaveV3;
    AaveV2ScUsdcAdapter aaveV2;
    MorphoAaveV3ScUsdcAdapter morpho;
    PriceConverter priceConverter;
    RebalanceScUsdcV2TestHarness script;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18488739);

        script = new RebalanceScUsdcV2TestHarness();

        vault = scUSDCv2(MainnetAddresses.SCUSDCV2);
        priceConverter = PriceConverter(address(vault.priceConverter()));
        morpho = script.morphoAdapter();
        aaveV2 = script.aaveV2Adapter();
        aaveV3 = script.aaveV3Adapter();
    }

    function test_run_initialRebalance() public {
        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertTrue(script.assetBalance() > 0, "usdc balance");

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.assetBalance() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usdc balance");
    }

    function test_run_failsIfTotalInvestableAmountPercentNot100() public {
        script.setMorphoInvestableAmountPercent(0.5e18);
        script.setAaveV2InvestableAmountPercent(0.5e18);
        script.setAaveV3InvestableAmountPercent(0.5e18);

        vm.expectRevert("investable amount percent not 100%");
        script.run();
    }

    function test_run_twoAdaptersInitialRebalance() public {
        uint256 morphoInvestableAmountPercent = 0.4e18;
        uint256 aaveV2InvestableAmountPercent = 0.6e18;
        script.setMorphoInvestableAmountPercent(morphoInvestableAmountPercent);
        script.setAaveV2InvestableAmountPercent(aaveV2InvestableAmountPercent);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.assetBalance() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usdc balance");

        uint256 morphoExpectedCollateral = expectedCollateral.mulWadDown(morphoInvestableAmountPercent);
        uint256 aaveV2ExpectedCollateral = expectedCollateral.mulWadDown(aaveV2InvestableAmountPercent);
        uint256 morphoExpectedDebt =
            priceConverter.usdcToEth(morphoExpectedCollateral).mulWadDown(script.morphoTargetLtv());
        uint256 aaveV2ExpectedDebt =
            priceConverter.usdcToEth(aaveV2ExpectedCollateral).mulWadDown(script.aaveV2TargetLtv());

        assertApproxEqRel(vault.getCollateral(morpho.id()), morphoExpectedCollateral, 0.001e18, "morpho collateral");
        assertApproxEqRel(vault.getCollateral(aaveV2.id()), aaveV2ExpectedCollateral, 0.001e18, "aave v2 collateral");
        assertApproxEqRel(vault.getDebt(morpho.id()), morphoExpectedDebt, 0.001e18, "morpho debt");
        assertApproxEqRel(vault.getDebt(aaveV2.id()), aaveV2ExpectedDebt, 0.001e18, "aave v2 debt");
    }

    function test_run_leverageDownByRepayingDebt() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        uint256 newTargetLtv = script.morphoTargetLtv() - 0.1e18;
        script.setMorphoTargetLtv(newTargetLtv);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalCollateral();
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(newTargetLtv);

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usdc balance");
    }

    function test_run_twoAdaptersLeverageDown() public {
        script.setMorphoInvestableAmountPercent(0.4e18);
        script.setAaveV2InvestableAmountPercent(0.6e18);

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        uint256 newMorphoTargetLtv = script.morphoTargetLtv() - 0.1e18;
        uint256 newAaveV2TargetLtv = script.aaveV2TargetLtv() - 0.2e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);
        script.setAaveV2TargetLtv(newAaveV2TargetLtv);

        uint256 morphoExpectedCollateral = vault.getCollateral(morpho.id());
        uint256 moprhoExpectedDebt = priceConverter.usdcToEth(morphoExpectedCollateral).mulWadDown(newMorphoTargetLtv);
        uint256 aaveV2ExpectedCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2ExpectedDebt = priceConverter.usdcToEth(aaveV2ExpectedCollateral).mulWadDown(newAaveV2TargetLtv);

        script.run();

        assertApproxEqRel(vault.getCollateral(morpho.id()), morphoExpectedCollateral, 0.001e18, "morpho collateral");
        assertApproxEqRel(vault.getCollateral(aaveV2.id()), aaveV2ExpectedCollateral, 0.001e18, "aave v2 collateral");
        assertApproxEqRel(vault.getDebt(morpho.id()), moprhoExpectedDebt, 0.001e18, "morpho debt");
        assertApproxEqRel(vault.getDebt(aaveV2.id()), aaveV2ExpectedDebt, 0.001e18, "aave v2 debt");
    }

    function test_run_twoAdaptersOneLeverageDownOtherUp() public {
        script.setMorphoInvestableAmountPercent(0.5e18);
        script.setAaveV2InvestableAmountPercent(0.5e18);
        script.setAaveV2TargetLtv(0.5e18);

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        uint256 newMorphoTargetLtv = script.morphoTargetLtv() - 0.1e18;
        uint256 newAaveV2TargetLtv = script.aaveV2TargetLtv() + 0.1e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);
        script.setMorphoInvestableAmountPercent(0);
        script.setAaveV2TargetLtv(newAaveV2TargetLtv);
        script.setAaveV2InvestableAmountPercent(1e18);

        uint256 morphoExpectedCollateral = vault.getCollateral(morpho.id());
        uint256 moprhoExpectedDebt = priceConverter.usdcToEth(morphoExpectedCollateral).mulWadDown(newMorphoTargetLtv);
        uint256 aaveV2ExpectedCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2ExpectedDebt = priceConverter.usdcToEth(aaveV2ExpectedCollateral).mulWadDown(newAaveV2TargetLtv);

        script.run();

        assertApproxEqRel(vault.getCollateral(morpho.id()), morphoExpectedCollateral, 0.001e18, "morpho collateral");
        assertApproxEqRel(vault.getCollateral(aaveV2.id()), aaveV2ExpectedCollateral, 0.001e18, "aave v2 collateral");
        assertApproxEqRel(vault.getDebt(morpho.id()), moprhoExpectedDebt, 0.001e18, "morpho debt");
        assertApproxEqRel(vault.getDebt(aaveV2.id()), aaveV2ExpectedDebt, 0.001e18, "aave v2 debt");
    }

    function test_run_leverageDownByAddingMoreCollateral() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        // additional deposit
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        uint256 newMorphoTargetLtv = script.morphoTargetLtv() - 0.1e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(newMorphoTargetLtv);
        uint256 debtBefore = vault.totalDebt();

        script.run();

        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usdc balance");
        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertTrue(vault.totalDebt() >= debtBefore, "total debt decreased");
    }

    function test_run_leverageDownByAddingMoreCollateralAndRepayingDebt() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        // additional deposit
        deal(address(vault.asset()), address(this), 1e6);
        vault.asset().approve(address(vault), 1e6);
        vault.deposit(1e6, address(this));

        uint256 newMorphoTargetLtv = script.morphoTargetLtv() - 0.5e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(newMorphoTargetLtv);
        uint256 debtBefore = vault.totalDebt();

        script.run();

        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usdc balance");
        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertTrue(vault.totalDebt() <= debtBefore, "total debt increased");
    }

    function test_run_leverageUpByTakingMoreDebt() public {
        script.setMorphoTargetLtv(0.5e18);
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        uint256 newMorphoTargetLtv = 0.6e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(newMorphoTargetLtv);

        script.run();

        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usdc balance");
        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_restoresMissingFloat() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        vault.withdraw(script.assetBalance(), address(this), address(this));
        assertEq(script.assetBalance(), 0, "usdc balance");

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = vault.totalDebt();
        uint256 wethInvested = script.targetTokensInvested();

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), wethInvested, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_restoresMissingFloatOnLeverageUp() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        vault.withdraw(script.assetBalance(), address(this), address(this));
        assertEq(script.assetBalance(), 0, "usdc balance");

        uint256 newMorphoTargetLtv = script.morphoTargetLtv() + 0.05e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(newMorphoTargetLtv);

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_restoresMissingFloatOnLeverageDown() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        vault.withdraw(script.assetBalance(), address(this), address(this));
        assertEq(script.assetBalance(), 0, "usdc balance");

        uint256 newMorphoTargetLtv = script.morphoTargetLtv() - 0.05e18;
        script.setMorphoTargetLtv(newMorphoTargetLtv);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(newMorphoTargetLtv);

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_worksWithAaveV3AdapterAdded() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.setMorphoInvestableAmountPercent(0);
        script.setAaveV2InvestableAmountPercent(0);
        script.setAaveV3InvestableAmountPercent(1e18); // 100%
        uint256 newAaveV3TargetLtv = 0.5e18;
        script.setAaveV3TargetLtv(newAaveV3TargetLtv); // 50%

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 investableAmount = script.assetBalance() - expectedFloat;
        uint256 expectedAaveV3Debt = priceConverter.usdcToEth(investableAmount).mulWadDown(newAaveV3TargetLtv);

        script.run();

        assertApproxEqRel(vault.getCollateral(aaveV3.id()), investableAmount, 0.001e18, "aave v3 collateral");
        assertApproxEqRel(vault.getDebt(aaveV3.id()), expectedAaveV3Debt, 0.001e18, "aave v3 debt");
    }

    function test_run_failsIfInvestablePercentForUnsupportedAdapterNot0() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        vm.startPrank(MainnetAddresses.MULTISIG);
        vault.removeAdapter(aaveV3.id(), false);
        vm.stopPrank();
        assertTrue(!vault.isSupported(aaveV3.id()), "aave v3 shouldn't be supported");

        script.setMorphoInvestableAmountPercent(0.4e18);
        script.setAaveV2InvestableAmountPercent(0.4e18);
        script.setAaveV3InvestableAmountPercent(0.2e18); // 100%
        script.setAaveV3TargetLtv(0);

        vm.expectRevert(
            abi.encodePacked(
                scCrossAssetYieldVaultRebalanceScript.ScriptCannotUseUnsupportedAdapter.selector, aaveV3.id()
            )
        );
        script.run();
    }

    function test_run_failsIfLtvForUnsupportedAdapterNot0() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        vm.startPrank(MainnetAddresses.MULTISIG);
        vault.removeAdapter(aaveV3.id(), false);
        vm.stopPrank();
        assertTrue(!vault.isSupported(aaveV3.id()), "aave v3 shouldn't be supported");

        script.setMorphoInvestableAmountPercent(0.5e18);
        script.setAaveV2InvestableAmountPercent(0.5e18);
        script.setAaveV3InvestableAmountPercent(0);
        script.setAaveV3TargetLtv(0.5e18); // 50%

        vm.expectRevert(
            abi.encodePacked(
                scCrossAssetYieldVaultRebalanceScript.ScriptCannotUseUnsupportedAdapter.selector, aaveV3.id()
            )
        );
        script.run();
    }

    function test_run_worksIfInvestablePercentAndLtvForUnsupportedAdapterAre0() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        vm.startPrank(MainnetAddresses.MULTISIG);
        vault.removeAdapter(aaveV3.id(), false);
        vm.stopPrank();
        assertTrue(!vault.isSupported(aaveV3.id()), "aave v3 shouldn't be supported");

        script.setMorphoInvestableAmountPercent(0.5e18);
        script.setAaveV2InvestableAmountPercent(0.5e18);
        script.setAaveV3InvestableAmountPercent(0);
        script.setAaveV3TargetLtv(0);

        script.run();

        uint256 totalCollateral = vault.totalCollateral();
        uint256 totalDebt = vault.totalDebt();

        assertApproxEqAbs(morpho.getCollateral(address(vault)), totalCollateral / 2, 1, "morpho collateral");
        assertApproxEqAbs(morpho.getDebt(address(vault)), totalDebt / 2, 1, "morpho debt");
        assertApproxEqAbs(aaveV2.getCollateral(address(vault)), totalCollateral / 2, 1, "aave v2 collateral");
        assertApproxEqAbs(aaveV2.getDebt(address(vault)), totalDebt / 2, 1, "aave v2 debt");
        assertEq(aaveV3.getCollateral(address(vault)), 0, "aave v3 collateral");
        assertEq(aaveV3.getDebt(address(vault)), 0, "aave v3 debt");
    }

    function test_run_sellsProfitsAndReinvests() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state
        _assertInitialState();

        assertTrue(vault.getProfit() == 0, "profit != 0");

        uint256 wethInvested = script.targetTokensInvested();

        _simulate100PctProfit();

        uint256 wethProfit = vault.getProfit();
        assertApproxEqAbs(wethProfit, wethInvested, 1, "profit != wethInvested");

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 approxUsdcReinvested =
            priceConverter.ethToUsdc(wethProfit.mulWadDown(1e18 - script.maxProfitSellSlippage()));
        uint256 approxAdditionalDebt =
            priceConverter.usdcToEth(approxUsdcReinvested).mulWadDown(script.morphoTargetLtv());
        uint256 initialCollateral = vault.totalCollateral();
        uint256 initialDebt = vault.totalDebt();

        script.setMinUsdcProfitToReinvest(10e6); // 10 usdc
        script.run();

        assertApproxEqAbs(vault.getProfit(), 0, 2, "profit not sold entirely");
        assertTrue(script.assetBalance() >= expectedFloat, "float balance");
        assertApproxEqRel(
            vault.totalCollateral(), initialCollateral + approxUsdcReinvested, 0.01e18, "total collateral"
        );
        assertApproxEqRel(vault.totalDebt(), initialDebt + approxAdditionalDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.targetTokensInvested(), wethInvested + approxAdditionalDebt, 0.01e18, "weth invested");
    }

    function test_run_doesntSellProfitIfBelowDefinedMin() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state
        _assertInitialState();

        assertTrue(vault.getProfit() == 0, "profit != 0");

        _simulate100PctProfit();

        uint256 wethProfit = vault.getProfit();
        // set min profit to reinvest to 2x the actual profit
        script.setMinUsdcProfitToReinvest(priceConverter.ethToUsdc(wethProfit * 2));

        uint256 wethInvested = script.targetTokensInvested();
        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 initialCollateral = vault.totalCollateral();
        uint256 initialDebt = vault.totalDebt();

        uint256 missingFloat = expectedFloat - script.assetBalance();
        uint256 wethDisinvested = priceConverter.usdcToEth(missingFloat);

        script.run();

        assertEq(vault.getProfit(), wethProfit, "profit");
        assertTrue(script.assetBalance() >= expectedFloat, "float balance");
        assertApproxEqRel(vault.totalCollateral(), initialCollateral - missingFloat, 0.005e18, "total collateral");
        assertApproxEqRel(vault.totalDebt(), initialDebt, 0.005e18, "total debt");
        assertApproxEqRel(script.targetTokensInvested(), wethInvested - wethDisinvested, 0.005e18, "weth invested");
    }

    function test_run_failsIfRealizedSlippageOnSellingProfitsIsTooHigh() public {
        // make a big deposit so that the profit is big enough to trigger the slippage check
        deal(address(vault.asset()), address(this), 10_000_000e6);
        vault.asset().approve(address(vault), 10_000_000e6);
        vault.deposit(10_000_000e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state
        _assertInitialState();

        assertTrue(vault.getProfit() == 0, "profit != 0");

        _simulate100PctProfit();

        script.setMaxProfitSellSlippage(0.001e18); // 0.1%

        vm.expectRevert("Too little received");
        script.run();
    }

    function test_run_usesProfitSellingToLeverageDown() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        _assertInitialState();

        uint256 wethInvested = script.targetTokensInvested();
        _simulate100PctProfit();
        assertApproxEqAbs(vault.getProfit(), wethInvested, 1, "profit != wethInvested");

        // reduce the leverage enough that the selling profit & reinvesting covers the difference
        uint256 targetLtv = script.morphoTargetLtv() - 0.25e18;
        script.setMorphoTargetLtv(targetLtv);

        uint256 initialCollateral = vault.totalCollateral();
        uint256 initialDebt = vault.totalDebt();
        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(targetLtv);

        script.setMinUsdcProfitToReinvest(10e6); // 10 usdc
        script.run();

        assertApproxEqAbs(vault.getProfit(), 0, 2, "profit not sold entirely");
        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertTrue(vault.totalCollateral() > initialCollateral, "total collateral not increased");
        assertTrue(vault.totalDebt() >= initialDebt, "total debt decreased");

        uint256 currentLtv = priceConverter.ethToUsdc(vault.totalDebt()).divWadDown(vault.totalCollateral());
        assertApproxEqAbs(currentLtv, targetLtv, 0.05e18, "current ltv");
    }

    function _assertInitialState() internal {
        assertTrue(script.targetTokensInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(script.assetBalance() > 0, "usdc balance");
    }

    function _simulate100PctProfit() internal {
        WETH weth = WETH(payable(C.WETH));

        // simulate 100% profit by dealing more WETH to scWETH vault
        deal(
            address(weth),
            address(script.targetVault()),
            script.targetVault().totalAssets() + weth.balanceOf(address(script.targetVault()))
        );
    }
}

contract RebalanceScUsdcV2TestHarness is RebalanceScUsdcV2 {
    function setMinUsdcProfitToReinvest(uint256 _minUsdcProfitToReinvest) public {
        minProfitToReinvest = _minUsdcProfitToReinvest;
    }

    function setMaxProfitSellSlippage(uint256 _maxProfitSellSlippage) public {
        maxProfitSellSlippage = _maxProfitSellSlippage;
    }

    function setMorphoTargetLtv(uint256 _newTargetLtv) public {
        morphoTargetLtv = _newTargetLtv;
    }

    function setMorphoInvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        morphoInvestableAmountPercent = _newInvestableAmountPercent;
    }

    function setAaveV2TargetLtv(uint256 _newTargetLtv) public {
        aaveV2TargetLtv = _newTargetLtv;
    }

    function setAaveV2InvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        aaveV2InvestableAmountPercent = _newInvestableAmountPercent;
    }

    function setAaveV3TargetLtv(uint256 _newTargetLtv) public {
        aaveV3TargetLtv = _newTargetLtv;
    }

    function setAaveV3InvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        aaveV3InvestableAmountPercent = _newInvestableAmountPercent;
    }
}
