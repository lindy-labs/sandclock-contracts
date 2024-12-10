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
import {IRewardsController} from "src/interfaces/aave-v3/IRewardsController.sol";
import {scUSDSv2} from "src/steth/scUSDSv2.sol";
import {AaveV3ScUsdsAdapter} from "src/steth/scUsds-adapters/AaveV3ScUsdsAdapter.sol";
import {DaiWethPriceConverter} from "src/steth/priceConverter/DaiWethPriceConverter.sol";
import {UsdsWethSwapper} from "src/steth/swapper/UsdsWethSwapper.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";

import {RebalanceScUsdsV2} from "script/v2/keeper-actions/RebalanceScUsdsV2.s.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "script/base/scCrossAssetYieldVaultRebalanceScript.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";

contract RebalanceScUsdsV2Test is Test {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 mainnetFork;

    scUSDSv2 vault;
    AaveV3ScUsdsAdapter aaveV3;
    DaiWethPriceConverter priceConverter;
    RebalanceScUsdsV2TestHarness script;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21366396);

        aaveV3 = new AaveV3ScUsdsAdapter();
        priceConverter = new DaiWethPriceConverter();
        UsdsWethSwapper swapper = new UsdsWethSwapper();

        vault = new scUSDSv2(
            address(this), MainnetAddresses.KEEPER, ERC4626(MainnetAddresses.SCWETHV2), priceConverter, swapper
        );

        vault.addAdapter(aaveV3);

        // add same keeper role as the one used in the mainnet
        vault.grantRole(vault.KEEPER_ROLE(), 0x3Ab6EBDBf08e1954e69F6859AdB2DA5236D2e838);

        // make an initial deposit
        deal(C.USDS, address(this), 1000e18);
        ERC20(C.USDS).safeApprove(address(vault), 1000e18);
        vault.deposit(1000e18, address(this));

        script = new RebalanceScUsdsV2TestHarness(vault);
    }

    function test_run_initialRebalance() public {
        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(script.totalDebt(), 0, "total debt");
        assertEq(script.totalCollateral(), 0, "total collateral");
        assertTrue(script.assetBalance() > 0, "usds balance");

        uint256 expectedFloat = script.assetBalance().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.assetBalance() - expectedFloat;
        uint256 expectedDebt =
            priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.aaveV3TargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.001e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.001e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.001e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.001e18, "usds balance");
    }

    function test_run_rebalanceWithProfit() public {
        script.run();

        _assertInitialState();

        _simulate100PctProfit();

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral().mulWadDown(1e18 + script.aaveV3TargetLtv());
        uint256 expectedDebt =
            priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.aaveV3TargetLtv());

        script = new RebalanceScUsdsV2TestHarness(vault);
        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.6e18, "usds balance");
    }

    function test_run_canDeleverage() public {
        script.run();

        _assertInitialState();

        script = new RebalanceScUsdsV2TestHarness(vault);
        script.setAaveV3TargetLtv(0.2e18);

        uint256 expectedFloat = script.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 expectedCollateral = script.totalCollateral();
        uint256 expectedDebt =
            priceConverter.assetToTargetToken(expectedCollateral).mulWadDown(script.aaveV3TargetLtv());

        script.run();

        assertApproxEqRel(script.targetTokensInvested(), expectedDebt, 0.01e18, "weth invested");
        assertApproxEqRel(script.totalDebt(), expectedDebt, 0.01e18, "total debt");
        assertApproxEqRel(script.totalCollateral(), expectedCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(script.assetBalance(), expectedFloat, 0.4e18, "usds balance");
    }

    function _assertInitialState() internal {
        assertTrue(script.targetTokensInvested() > 0, "initial weth invested 0");
        assertTrue(vault.totalDebt() > 0, "initial total debt 0");
        assertTrue(vault.totalCollateral() > 0, "initial  total collateral 0");
        assertTrue(script.assetBalance() > 0, "initial usds balance 0");
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

    function test_run_claimsRewards() public {
        vault = scUSDSv2(MainnetAddresses.SCUSDSV2);

        script = new RebalanceScUsdsV2TestHarness(vault);

        address[] memory assets = new address[](1);
        assets[0] = C.AAVE_V3_AUSDS_TOKEN;
        uint256 claimable = IRewardsController(C.AAVE_V3_REWARDS_CONTROLLER).getUserRewards(
            assets, address(vault), 0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259
        );

        uint256 totalAssetsBefore = vault.totalAssets();

        script.run();

        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore + claimable, 1, "rewards not claimed");
    }
}

contract RebalanceScUsdsV2TestHarness is RebalanceScUsdsV2 {
    constructor(scUSDSv2 _vault) {
        vault = _vault;
    }

    function _initEnv() internal override {
        // TODO: WRONG KEEPER ADDRESS???
        keeper = 0x3Ab6EBDBf08e1954e69F6859AdB2DA5236D2e838;
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
