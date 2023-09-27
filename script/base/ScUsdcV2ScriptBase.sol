// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {MainnetAddresses} from "./MainnetAddresses.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";

/**
 * A base script for executing keeper functions on scUsdcV2 vault.
 */
abstract contract ScUsdcV2ScriptBase is Script {
    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x0)));
    // if keeper private key is not provided, use the default keeper address for running the script tests
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MainnetAddresses.KEEPER;

    scUSDCv2 public scUsdcV2 = scUSDCv2(vm.envOr("SC_USDC_V2", MainnetAddresses.SCUSDCV2));

    PriceConverter priceConverter = PriceConverter(vm.envOr("PRICE_CONVERTER", MainnetAddresses.PRICE_CONVERTER));

    MorphoAaveV3ScUsdcAdapter public morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter public aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter public aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    function setKeeperPrivateKey(uint256 _privateKey) public {
        keeperPrivateKey = _privateKey;
        keeper = vm.addr(keeperPrivateKey);
    }

    function setVault(scUSDCv2 _scUsdcV2) public {
        scUsdcV2 = _scUsdcV2;
    }
}
