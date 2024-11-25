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
import {scWBTC} from "src/steth/scWBTC.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {ExitAllPositionsScWbtc} from "script/v2/keeper-actions/ExitAllPositionsScWbtc.s.sol";
import {AaveV3ScWbtcAdapter} from "src/steth/scWbtc-adapters/AaveV3ScWbtcAdapter.sol";
import {WbtcWethPriceConverter} from "src/steth/priceConverter/WbtcWethPriceConverter.sol";
import {WbtcWethSwapper} from "src/steth/swapper/WbtcWethSwapper.sol";

contract ExitAllPositionsScWbtcTest is Test {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    scWBTC vault;
    WbtcWethPriceConverter priceConverter;
    ExitAllPositionsScWbtc script;

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21209561);

        // TODO: use deployed addresses here instead of creating new instances when deployed on mainnet
        priceConverter = new WbtcWethPriceConverter();
        WbtcWethSwapper swapper = new WbtcWethSwapper();

        vault = new scWBTC(
            address(this), MainnetAddresses.KEEPER, ERC4626(MainnetAddresses.SCWETHV2), priceConverter, swapper
        );

        vault.addAdapter(new AaveV3ScWbtcAdapter());

        // make an initial deposit
        uint256 depositAmount = 1e8; // 1 WBTC
        deal(C.WBTC, address(this), depositAmount);
        ERC20(C.WBTC).safeApprove(address(vault), depositAmount);
        vault.deposit(depositAmount, address(this));

        console2.log(ERC20(C.WBTC).balanceOf(address(vault)));

        script = new ExitAllPositionsScWbtcTestHarness(vault);
    }

    function test_run_exitsAllPositions() public {
        assertEq(script.targetTokensInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertTrue(vault.asset().balanceOf(address(vault)) > 0, "wbtc balance");

        // deposit
        deal(address(vault.asset()), address(this), 1000e18);
        vault.asset().safeApprove(address(vault), 1000e18);
        vault.deposit(1000e6, address(this));

        // rebalance to create some debt & collateral positions
        uint256 investAmount = vault.asset().balanceOf(address(vault)).mulWadDown(0.9e18);
        uint256 debtAmount = priceConverter.assetToTargetToken(investAmount).mulWadDown(0.7e18);

        _rebalance(investAmount, debtAmount);

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

        assertApproxEqAbs(script.targetTokensInvested(), debtAmount.mulWadDown(1.2e18), 1, "weth invested");
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
        bytes[] memory callData = new bytes[](2);

        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, 1, investAmount);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, 1, debtAmount);

        vm.prank(MainnetAddresses.KEEPER);
        vault.rebalance(callData);
    }
}

contract ExitAllPositionsScWbtcTestHarness is ExitAllPositionsScWbtc {
    constructor(scCrossAssetYieldVault _vault) {
        vault = _vault;
    }

    function _getVaultAddress() internal view override returns (scCrossAssetYieldVault) {
        return vault;
    }
}
