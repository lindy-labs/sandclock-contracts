// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {RebalanceScUsdcV2} from "../../script/v2/actions/RebalanceScUsdcV2.s.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";
import {Constants} from "../../src/lib/Constants.sol";

import {RedeployScript} from "../../script/v2/RedeployScUsdcV2EthMainnet.s.sol";
import {ExitAllPositionsScUsdcV2} from "../../script/v2/actions/ExitAllPositionsScUsdcV2.s.sol";

contract ExitAllPositionsScUsdcV2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    scUSDCv2 vault;
    AaveV3ScUsdcAdapter aaveV3;
    AaveV2ScUsdcAdapter aaveV2;
    MorphoAaveV3ScUsdcAdapter morpho;
    PriceConverter priceConverter;
    ExitAllPositionsScUsdcV2TestHarness script;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17987643);

        // TODO: use a mainnet (instead of redeploying) address for the vault when scUSDCv2 is deployed on mainnet
        RedeployScriptTestHarness redeployScript = new RedeployScriptTestHarness();
        redeployScript.setDeployerAddress(address(this));
        vault = redeployScript.run();
        console2.log("depolyed");
        priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);

        script = new ExitAllPositionsScUsdcV2TestHarness();
    }

    function test_run_exitsAllPositions() public {
        assertEq(vault.wethInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertTrue(vault.usdcBalance() > 0, "usdc balance");

        // deposit
        deal(address(vault.asset()), address(this), 1000e6);
        vault.asset().approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));

        // rebalance
        bytes[] memory callData = new bytes[](4);
        uint256 investAmount = 900e6;
        uint256 debtAmount = priceConverter.usdcToEth(investAmount).mulWadDown(0.7e18);

        callData[0] = abi.encodeWithSelector(scUSDCv2.supply.selector, 1, investAmount / 2);
        callData[1] = abi.encodeWithSelector(scUSDCv2.supply.selector, 4, investAmount / 2);
        callData[2] = abi.encodeWithSelector(scUSDCv2.borrow.selector, 1, debtAmount / 2);
        callData[3] = abi.encodeWithSelector(scUSDCv2.borrow.selector, 4, debtAmount / 2);

        vm.prank(MainnetAddresses.KEEPER);
        vault.rebalance(callData);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 maxLossPercent = script.maxAceeptableLossPercent();

        assertEq(vault.wethInvested(), debtAmount, "weth invested");
        assertEq(vault.totalDebt(), debtAmount, "total debt");
        assertEq(vault.totalCollateral(), investAmount, "total collateral");

        // exit
        script.setScUsdcV2Vault(vault);
        script.run();

        assertEq(vault.wethInvested(), 0, "weth invested");
        assertEq(vault.totalDebt(), 0, "total debt");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore, maxLossPercent, "total assets");
    }
}

contract ExitAllPositionsScUsdcV2TestHarness is ExitAllPositionsScUsdcV2 {
    function setScUsdcV2Vault(scUSDCv2 _vault) public {
        scUsdcV2 = _vault;
    }
}

contract RedeployScriptTestHarness is RedeployScript {
    function setDeployerAddress(address _deployerAddress) public {
        deployerAddress = _deployerAddress;
    }
}
