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
 * forge script script/v2/manual-runs/scWETHv2Rebalane.s.sol --skip-simulation -vv
 */
contract scWETHv2Rebalance is Test {
    using FixedPointMathLib for uint256;

    uint256 keeperPrivateKey = uint256(vm.envBytes32("KEEPER_PRIVATE_KEY"));

    // uint256 mainnetFork;

    function run() external {
        // _fork(17529069);
        vm.startBroadcast(deployerAddress);

        uint256 aaveV3AllocationPercent = 0.3e18;
        uint256 compoundV3AllocationPercent = 0.7e18;

        vm.stopBroadcast();

        vm.startBroadcast(keeper);
        _invest(weth.balanceOf(address(vault)), aaveV3AllocationPercent, compoundV3AllocationPercent);
        vm.stopBroadcast();

        console.log("Assets before time skip", vault.totalAssets());

        // fast forward 365 days in time and simulate an annual staking interest of 7.1%
        _simulate_stEthStakingInterest(365 days, 1.071e18);

        console.log("Assets after time skip", vault.totalAssets());
    }
}
