// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {RebalanceScUsdcV2} from "../../script/v2/RebalanceScUsdcV2.s.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";

contract RebalanceScUsdcV2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    scUSDCv2 vault;
    AaveV3ScUsdcAdapter aaveV3;
    AaveV2ScUsdcAdapter aaveV2;
    MorphoAaveV3ScUsdcAdapter morpho;
    PriceConverter priceConverter;
    RebalanceScUsdcV2TestHarness script;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17920182);

        script = new RebalanceScUsdcV2TestHarness();

        vault = scUSDCv2(MainnetAddresses.SCUSDCV2);
        priceConverter = vault.priceConverter();
        morpho = script.morphoAdapter();
        aaveV2 = script.aaveV2Adapter();
        aaveV3 = script.aaveV3Adapter();
    }

    function test_run_initialRebalance() public {
        assertEq(vault.wethInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.usdcBalance() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(vault.usdcBalance(), expectedFloat, 0.001e18, "usdc balance");
    }

    function test_run_twoAdaptersInitialRebalance() public {
        uint256 morphoInvestableAmountPercent = 0.4e18;
        uint256 aaveV2InvestableAmountPercent = 0.6e18;
        script.setMorphoInvestableAmountPercent(morphoInvestableAmountPercent);
        script.setAaveV2InvestableAmountPercent(aaveV2InvestableAmountPercent);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.usdcBalance() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(vault.usdcBalance(), expectedFloat, 0.001e18, "usdc balance");

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

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        script.setMorphoTargetLtv(script.morphoTargetLtv() - 0.1e18);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalCollateral();
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(vault.usdcBalance(), expectedFloat, 0.001e18, "usdc balance");
    }

    function test_run_twoAdaptersLeverageDown() public {
        script.setMorphoInvestableAmountPercent(0.4e18);
        script.setAaveV2InvestableAmountPercent(0.6e18);

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        script.setMorphoTargetLtv(script.morphoTargetLtv() - 0.1e18);
        script.setAaveV2TargetLtv(script.aaveV2TargetLtv() - 0.2e18);

        uint256 morphoExpectedCollateral = vault.getCollateral(morpho.id());
        uint256 moprhoExpectedDebt =
            priceConverter.usdcToEth(morphoExpectedCollateral).mulWadDown(script.morphoTargetLtv());
        uint256 aaveV2ExpectedCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2ExpectedDebt =
            priceConverter.usdcToEth(aaveV2ExpectedCollateral).mulWadDown(script.aaveV2TargetLtv());

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

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        script.setMorphoTargetLtv(script.morphoTargetLtv() - 0.1e18);
        script.setAaveV2TargetLtv(script.aaveV2TargetLtv() + 0.1e18);

        uint256 morphoExpectedCollateral = vault.getCollateral(morpho.id());
        uint256 moprhoExpectedDebt =
            priceConverter.usdcToEth(morphoExpectedCollateral).mulWadDown(script.morphoTargetLtv());
        uint256 aaveV2ExpectedCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2ExpectedDebt =
            priceConverter.usdcToEth(aaveV2ExpectedCollateral).mulWadDown(script.aaveV2TargetLtv());

        script.run();

        assertApproxEqRel(vault.getCollateral(morpho.id()), morphoExpectedCollateral, 0.001e18, "morpho collateral");
        assertApproxEqRel(vault.getCollateral(aaveV2.id()), aaveV2ExpectedCollateral, 0.001e18, "aave v2 collateral");
        assertApproxEqRel(vault.getDebt(morpho.id()), moprhoExpectedDebt, 0.001e18, "morpho debt");
        assertApproxEqRel(vault.getDebt(aaveV2.id()), aaveV2ExpectedDebt, 0.001e18, "aave v2 debt");
    }

    function test_run_leverageDownByAddingMoreCollateral() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        // additional deposit
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.setMorphoTargetLtv(script.morphoTargetLtv() - 0.1e18);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.usdcBalance(), expectedFloat, 0.001e18, "usdc balance");
        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_leverageDownByAddingMoreCollateralAndRepayingDebt() public {
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        // additional deposit
        deal(address(vault.asset()), address(this), 1e6);
        vault.asset().approve(address(vault), 1e6);
        vault.deposit(1e6, address(this));

        script.setMorphoTargetLtv(script.morphoTargetLtv() - 0.5e18);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_leverageUpByTakingMoreDebt() public {
        script.setMorphoTargetLtv(0.5e18);
        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        script.setMorphoTargetLtv(0.6e18);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_restoresMissingFloat() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        vault.withdraw(vault.usdcBalance(), address(this), address(this));
        assertEq(vault.usdcBalance(), 0, "usdc balance");

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_restoresMissingFloatOnLeverageUp() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        vault.withdraw(vault.usdcBalance(), address(this), address(this));
        assertEq(vault.usdcBalance(), 0, "usdc balance");

        script.setMorphoTargetLtv(script.morphoTargetLtv() + 0.05e18);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }

    function test_run_restoresMissingFloatOnLeverageDown() public {
        deal(address(vault.asset()), address(this), 100e6);
        vault.asset().approve(address(vault), 100e6);
        vault.deposit(100e6, address(this));

        script.run(); // initial rebalance
        script = new RebalanceScUsdcV2TestHarness(); // reset script state

        assertTrue(vault.wethInvested() > 0, "weth invested");
        assertTrue(vault.totalDebt() > 0, "total debt");
        assertTrue(vault.totalCollateral() > 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        vault.withdraw(vault.usdcBalance(), address(this), address(this));
        assertEq(vault.usdcBalance(), 0, "usdc balance");

        script.setMorphoTargetLtv(script.morphoTargetLtv() - 0.05e18);

        uint256 expectedFloat = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = vault.totalAssets() - expectedFloat;
        uint256 expectedDebt = priceConverter.usdcToEth(expectedCollateral).mulWadDown(script.morphoTargetLtv());

        script.run();

        assertApproxEqRel(vault.wethInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(vault.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(vault.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
    }
}

contract RebalanceScUsdcV2TestHarness is RebalanceScUsdcV2 {
    function setUseMorpho(bool _isUsed) public {
        useMorpho = _isUsed;
    }

    function setMorphoTargetLtv(uint256 _newTargetLtv) public {
        morphoTargetLtv = _newTargetLtv;
    }

    function setMorphoInvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        morphoInvestableAmountPercent = _newInvestableAmountPercent;
    }

    function setUseAaveV2(bool _isUsed) public {
        useAaveV2 = _isUsed;
    }

    function setAaveV2TargetLtv(uint256 _newTargetLtv) public {
        aaveV2TargetLtv = _newTargetLtv;
    }

    function setAaveV2InvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        aaveV2InvestableAmountPercent = _newInvestableAmountPercent;
    }

    function setUseAaveV3(bool _isUsed) public {
        useAaveV3 = _isUsed;
    }

    function setAaveV3TargetLtv(uint256 _newTargetLtv) public {
        aaveV3TargetLtv = _newTargetLtv;
    }

    function setAaveV3InvestableAmountPercent(uint256 _newInvestableAmountPercent) public {
        aaveV3InvestableAmountPercent = _newInvestableAmountPercent;
    }
}