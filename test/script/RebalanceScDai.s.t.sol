// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {RebalanceScUsdcV2} from "../../script/v2/keeper-actions/RebalanceScUsdcV2.s.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";
import {Constants} from "../../src/lib/Constants.sol";

contract RebalanceScDaiTest is Test {
    uint256 mainnetFork;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        // vm.selectFork(mainnetFork);
        // vm.rollFork(18488739);

        // script = new RebalanceScUsdcV2TestHarness();

        // vault = scUSDCv2(MainnetAddresses.SCDAI);
        // priceConverter = vault.priceConverter();
        // spark = script.sparkAdapter();
    }
}
