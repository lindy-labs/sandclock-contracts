// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {scLiquity} from "src/liquity/scLiquity.sol";
import {IStabilityPool} from "src/interfaces/liquity/IStabilityPool.sol";
import {Constants as C} from "src/lib/Constants.sol";

/**
 * @title HarvestScLiquity
 * @notice A script for executing harvest functionality on scLiquity vault
 * @dev This script claims LQTY and ETH rewards from Liquity Stability Pool and swaps them to LUSD
 */
contract HarvestScLiquity is Script {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // Minimum amounts to make harvesting worthwhile (gas cost considerations)
    uint256 public minLQTYAmount = 10e18; // 10 LQTY token
    uint256 public minETHAmount = 1e15; // 0.001 ETH

    // Slippage tolerance for swaps
    uint256 public lqtySlippageTolerance = 30e16; // 30% (LQTY can be volatile)
    uint256 public ethSlippageTolerance = 5e16; // 5% (ETH is more stable)

    /*//////////////////////////////////////////////////////////////*/

    // Contract instances
    scLiquity vault;
    IStabilityPool stabilityPool;
    IERC20 lqty;
    IERC20 lusd;
    address keeper;

    function run() external {
        console2.log("--- ScLiquity Harvest script running ---");

        // Initialize contracts and keeper
        _init();

        // Log initial state
        _logState("\t\t--- Initial State ---");

        // Check if harvest is profitable
        (bool shouldHarvest, uint256 totalLQTY, uint256 totalETH) = _shouldHarvest();

        if (!shouldHarvest) {
            console2.log("Harvest not profitable - amounts below minimum thresholds");
            console2.log("--- ScLiquity Harvest script done ---");
            return;
        }

        // Prepare swap data
        bytes memory lqtySwapData = totalLQTY > 0 ? _createLQTYSwapData(totalLQTY) : new bytes(0);
        bytes memory ethSwapData = totalETH > 0 ? _createETHSwapData(totalETH) : new bytes(0);

        // Execute harvest
        console2.log("Executing harvest...");
        console2.log("LQTY amount:", totalLQTY);
        console2.log("ETH amount:", totalETH);

        vm.startBroadcast(keeper);
        vault.harvest(totalLQTY, lqtySwapData, totalETH, ethSwapData);
        vm.stopBroadcast();

        // Log final state
        _logState("\t\t--- Final State ---");
        console2.log("--- ScLiquity Harvest script done ---");
    }

    function _init() internal {
        // Get vault address from environment or use default
        vault = scLiquity(payable(0xdb369eEB33fcfDCd1557E354dDeE7d6cF3146A11));

        // Initialize related contracts
        stabilityPool = IStabilityPool(C.LIQUITY_STABILITY_POOL);
        lqty = IERC20(C.LIQUITY_LQTY_TOKEN);
        lusd = IERC20(C.LUSD);

        // Get keeper from private key
        keeper = vm.rememberKey(vm.envUint("KEEPER_PRIVATE_KEY"));

        console2.log("Vault address:", address(vault));
        console2.log("Keeper address:", keeper);
    }

    function _shouldHarvest() internal view returns (bool shouldHarvest, uint256 totalLQTY, uint256 totalETH) {
        // Get current balances
        uint256 currentLQTY = lqty.balanceOf(address(vault));
        uint256 currentETH = address(vault).balance;

        // Get pending rewards
        uint256 pendingLQTY = stabilityPool.getDepositorLQTYGain(address(vault));
        uint256 pendingETH = stabilityPool.getDepositorETHGain(address(vault));

        // Calculate totals
        totalLQTY = currentLQTY + pendingLQTY;
        totalETH = currentETH + pendingETH;

        // Check if amounts meet minimum thresholds
        bool lqtyWorthwhile = totalLQTY >= minLQTYAmount;
        bool ethWorthwhile = totalETH >= minETHAmount;

        shouldHarvest = lqtyWorthwhile || ethWorthwhile;

        console2.log("\t-- Harvest Assessment --");
        console2.log("Current LQTY:", currentLQTY);
        console2.log("Pending LQTY:", pendingLQTY);
        console2.log("Total LQTY:", totalLQTY);
        console2.log("LQTY worthwhile:", lqtyWorthwhile);
        console2.log("");
        console2.log("Current ETH:", currentETH);
        console2.log("Pending ETH:", pendingETH);
        console2.log("Total ETH:", totalETH);
        console2.log("ETH worthwhile:", ethWorthwhile);
        console2.log("");
        console2.log("Should harvest:", shouldHarvest);
        console2.log("-----------------------------");
    }

    function _createLQTYSwapData(uint256 swapAmount) internal view returns (bytes memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = address(lqty); // LQTY
        tokens[1] = C.WETH; // WETH
        tokens[2] = address(lusd); // LUSD

        uint256 minLUSDAmount = swapAmount * (1e18 - lqtySlippageTolerance) / 1e18;

        return abi.encodeWithSignature(
            "sellToUniswap(address[],uint256,uint256,bool)", tokens, swapAmount, minLUSDAmount, false
        );
    }

    function _createETHSwapData(uint256 ethAmount) internal view returns (bytes memory) {
        // Uniswap V3 encoded path: ETH (WETH) -> LUSD
        bytes memory encodedPath = abi.encodePacked(
            C.WETH, // WETH
            uint24(3000), // 0.3% fee tier
            address(lusd) // LUSD
        );

        uint256 minBuyAmount = ethAmount * (1e18 - ethSlippageTolerance) / 1e18;
        address recipient = address(0); // Router handles return to caller

        return abi.encodeWithSignature(
            "sellEthForTokenToUniswapV3(bytes,uint256,address)", encodedPath, minBuyAmount, recipient
        );
    }

    function _logState(string memory _heading) internal view {
        console2.log(_heading);

        uint256 lqtyBalance = lqty.balanceOf(address(vault));
        uint256 ethBalance = address(vault).balance;
        uint256 lusdBalance = lusd.balanceOf(address(vault));
        uint256 stabilityDeposit = stabilityPool.getCompoundedLUSDDeposit(address(vault));
        uint256 totalAssets = vault.totalAssets();
        uint256 totalInvested = vault.totalInvested();

        console2.log("LQTY balance:\t\t\t", lqtyBalance);
        console2.log("ETH balance:\t\t\t", ethBalance);
        console2.log("LUSD balance:\t\t\t", lusdBalance);
        console2.log("Stability deposit:\t\t", stabilityDeposit);
        console2.log("Total assets:\t\t\t", totalAssets);
        console2.log("Total invested:\t\t", totalInvested);

        // Show pending rewards
        uint256 pendingLQTY = stabilityPool.getDepositorLQTYGain(address(vault));
        uint256 pendingETH = stabilityPool.getDepositorETHGain(address(vault));
        console2.log("Pending LQTY:\t\t\t", pendingLQTY);
        console2.log("Pending ETH:\t\t\t", pendingETH);

        console2.log("--------------------------------------------");
    }
}
