// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../../src/sc4626.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {AaveV3ScWethAdapter as scWethAaveV3Adapter} from "../../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter as scWethCompoundV3Adapter} from
    "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {AaveV3ScUsdcAdapter as scUsdcAaveV3Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter as scUsdcAaveV2Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {MainnetDeployBase} from "../../base/MainnetDeployBase.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";
import {scWETHv2Utils} from "../utils/scWETHv2Utils.sol";

/**
 * simulate initial rebalance in scWETHv2
 * forge script script/v2/manual-runs/scWETHv2Rebalance.s.sol --skip-simulation -vv
 */
contract scWETHv2Rebalance is scWETHv2Utils {
    using FixedPointMathLib for uint256;

    WETH weth = WETH(payable(C.WETH));
    // uint256 keeperPrivateKey = uint256(vm.envBytes32("KEEPER_PRIVATE_KEY"));

    address keeper = vm.envAddress("KEEPER");

    address localWhale = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        vm.startBroadcast(keeper);

        uint256 morphoAllocationPercent = 0.3e18;
        uint256 compoundV3AllocationPercent = 0.7e18;

        vault.deposit{value:10 ether}(localWhale);

        uint256 float = weth.balanceOf(address(vault));
        console2.log("\nInvesting %s weth", float);

        _invest(float, morphoAllocationPercent, compoundV3AllocationPercent);

        vm.stopBroadcast();
    }
}
