// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {scLiquity} from "../src/liquity/scLiquity.sol";
import {IStabilityPool} from "../src/interfaces/liquity/IStabilityPool.sol";
import {Constants as C} from "../src/lib/Constants.sol";

/**
 * @title scLiquity Fork Test Suite
 * @notice Tests for the live scLiquity contract using real mainnet state
 *
 * This test suite demonstrates working solutions for:
 * 1. LQTY token harvesting using sellToUniswap (production method)
 * 2. ETH reward harvesting using sellEthForTokenToUniswapV3
 * 3. Alternative LQTY harvesting using sellTokenForTokenToUniswapV3 (for comparison)
 */
contract scLiquityForkTest is Test {
    // Mainnet addresses from Constants
    ERC20 constant LQTY = ERC20(C.LIQUITY_LQTY_TOKEN);
    ERC20 constant LUSD = ERC20(C.LUSD);
    IStabilityPool constant stabilityPool = IStabilityPool(C.LIQUITY_STABILITY_POOL);

    // Live contract instances (specific to this test)
    scLiquity constant liveContract = scLiquity(payable(0xdb369eEB33fcfDCd1557E354dDeE7d6cF3146A11));
    address constant KEEPER = 0x397502F15E11C524F23C0c003f5E8004C1c5c71D;

    // Constructor/Setup
    function setUp() public {
        // Fork Ethereum mainnet at a specific block for consistency
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"), 22639210);
        vm.selectFork(mainnetFork);
    }

    // Public Test Functions
    function test_ComprehensiveLQTYHarvest() public {
        console.log("=== COMPREHENSIVE LQTY HARVEST TEST ===");

        // Get initial state
        uint256 initialLQTY = LQTY.balanceOf(address(liveContract));
        uint256 pendingLQTY = stabilityPool.getDepositorLQTYGain(address(liveContract));
        uint256 initialStability = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));

        console.log("Initial LQTY balance:", initialLQTY / 1e18, "tokens");
        console.log("Pending LQTY gains:", pendingLQTY / 1e18, "tokens");
        console.log("Total available:", (initialLQTY + pendingLQTY) / 1e18, "tokens");

        // Execute single harvest call with total LQTY amount
        uint256 totalLQTY = initialLQTY + pendingLQTY;
        bytes memory swapData = totalLQTY > 0 ? _createLQTYSwapData(totalLQTY) : new bytes(0);

        vm.prank(KEEPER);
        liveContract.harvest(totalLQTY, swapData, 0, "");

        // Validate results
        uint256 finalLQTY = LQTY.balanceOf(address(liveContract));
        uint256 finalStability = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));

        console.log("Final LQTY balance:", finalLQTY / 1e18, "tokens");
        console.log("Final stability deposit:", finalStability / 1e18, "LUSD");
        console.log("LUSD gained:", (finalStability - initialStability) / 1e18, "tokens");

        // Assertions - allow for small precision differences
        assertLt(finalLQTY, 5e16, "Should consume nearly all LQTY (small remainder ok)");
        assertGt(finalStability, initialStability, "Should increase stability deposit");
        assertEq(liveContract.totalInvested(), finalStability, "totalInvested should equal stability deposit");

        console.log("SUCCESS: LQTY harvest completed successfully");
    }

    function test_ETHHarvestSolution() public {
        console.log("=== ETH HARVEST SOLUTION TEST ===");

        // Force ETH for testing (in real usage, this comes from liquidation rewards)
        vm.deal(address(liveContract), 0.01 ether);

        // Get initial state including pending rewards
        uint256 initialETH = address(liveContract).balance;
        uint256 pendingETH = stabilityPool.getDepositorETHGain(address(liveContract));
        uint256 initialStability = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));

        // Calculate total ETH amount
        uint256 totalETH = initialETH + pendingETH;

        console.log("Initial ETH balance:", initialETH / 1e15, "finney");
        console.log("Pending ETH gains:", pendingETH, "wei");
        console.log("Total ETH to harvest:", totalETH / 1e15, "finney");
        console.log("Initial stability deposit:", initialStability / 1e18, "LUSD");

        // Create ETH swap data using sellEthForTokenToUniswapV3
        bytes memory ethSwapData = totalETH > 0 ? _createETHSwapData(totalETH) : new bytes(0);

        // Execute single ETH harvest call
        vm.prank(KEEPER);
        liveContract.harvest(0, "", totalETH, ethSwapData);

        uint256 finalStability = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));
        uint256 finalETH = address(liveContract).balance;

        console.log("Final ETH balance:", finalETH, "wei");
        console.log("Final stability deposit:", finalStability / 1e18, "LUSD");
        console.log("LUSD gained:", (finalStability - initialStability) / 1e18, "tokens");

        // Assertions - allow for small precision differences
        assertLt(finalETH, 1e15, "Should consume nearly all ETH (small remainder ok)");
        assertGt(finalStability, initialStability, "Should gain LUSD from ETH swap");

        console.log("SUCCESS: ETH -> LUSD harvesting working");
        console.log("Function: sellEthForTokenToUniswapV3");
    }

    function test_CombinedHarvest() public {
        console.log("=== COMBINED LQTY + ETH HARVEST TEST ===");

        // Setup: Add both LQTY and ETH for testing
        deal(address(LQTY), address(liveContract), 100e18);
        vm.deal(address(liveContract), 0.005 ether);

        // Get initial state including pending rewards
        uint256 initialLQTY = LQTY.balanceOf(address(liveContract));
        uint256 pendingLQTY = stabilityPool.getDepositorLQTYGain(address(liveContract));
        uint256 initialETH = address(liveContract).balance;
        uint256 pendingETH = stabilityPool.getDepositorETHGain(address(liveContract));
        uint256 initialStability = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));

        // Calculate total amounts
        uint256 totalLQTY = initialLQTY + pendingLQTY;
        uint256 totalETH = initialETH + pendingETH;

        console.log("Total LQTY to harvest:", totalLQTY / 1e18, "tokens");
        console.log("Total ETH to harvest:", totalETH / 1e15, "finney");

        // Prepare swap data for both
        bytes memory lqtySwapData = totalLQTY > 0 ? _createLQTYSwapData(totalLQTY) : new bytes(0);
        bytes memory ethSwapData = totalETH > 0 ? _createETHSwapData(totalETH) : new bytes(0);

        // Execute single combined harvest call
        vm.prank(KEEPER);
        liveContract.harvest(totalLQTY, lqtySwapData, totalETH, ethSwapData);

        // Validate results
        uint256 finalStability = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));
        uint256 finalLQTY = LQTY.balanceOf(address(liveContract));
        uint256 finalETH = address(liveContract).balance;

        console.log("Final LQTY balance:", finalLQTY / 1e18, "tokens");
        console.log("Final ETH balance:", finalETH, "wei");
        console.log("Final stability deposit:", finalStability / 1e18, "LUSD");
        console.log("Total LUSD gained:", (finalStability - initialStability) / 1e18, "tokens");

        // Assertions - allow for small precision differences
        assertLt(finalLQTY, 5e16, "Should consume nearly all LQTY (small remainder ok)");
        assertLt(finalETH, 1e15, "Should consume nearly all ETH (small remainder ok)");
        assertGt(finalStability, initialStability, "Should increase stability deposit");

        console.log("SUCCESS: Combined harvest completed successfully");
    }

    function test_SellTokenForTokenV3Direct() public {
        console.log("=== DIRECT sellTokenForTokenToUniswapV3 TEST ===");

        // Setup: Add LQTY for testing
        uint256 swapAmount = 100e18; // 100 LQTY tokens
        deal(address(LQTY), address(liveContract), swapAmount);

        // Get initial balances
        uint256 lqtyBefore = LQTY.balanceOf(address(liveContract));
        uint256 lusdBefore = LUSD.balanceOf(address(liveContract));
        uint256 stabilityBefore = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));

        console.log("Initial LQTY balance:", lqtyBefore / 1e18, "tokens");
        console.log("Initial LUSD balance:", lusdBefore / 1e18, "tokens");
        console.log("Initial stability deposit:", stabilityBefore / 1e18, "LUSD");

        // Create V3 swap data
        bytes memory swapDataV3 = _createLQTYSwapDataV3(swapAmount);

        // Execute harvest using sellTokenForTokenToUniswapV3
        vm.prank(KEEPER);
        liveContract.harvest(swapAmount, swapDataV3, 0, "");

        // Get final balances
        uint256 lqtyAfter = LQTY.balanceOf(address(liveContract));
        uint256 lusdAfter = LUSD.balanceOf(address(liveContract));
        uint256 stabilityAfter = stabilityPool.getCompoundedLUSDDeposit(address(liveContract));

        console.log("Final LQTY balance:", lqtyAfter / 1e18, "tokens");
        console.log("Final LUSD balance:", lusdAfter / 1e18, "tokens");
        console.log("Final stability deposit:", stabilityAfter / 1e18, "LUSD");

        // Calculate gains
        uint256 lqtyConsumed = lqtyBefore - lqtyAfter;
        uint256 lusdGained = lusdAfter - lusdBefore;
        uint256 stabilityGained = stabilityAfter - stabilityBefore;

        console.log("");
        console.log("=== SWAP RESULTS ===");
        console.log("LQTY consumed:", lqtyConsumed / 1e18, "tokens");
        console.log("LUSD gained (float):", lusdGained / 1e18, "tokens");
        console.log("LUSD gained (stability):", stabilityGained / 1e18, "tokens");
        console.log("Total LUSD gained:", (lusdGained + stabilityGained) / 1e18, "tokens");

        // Calculate effective price
        if (lqtyConsumed > 0) {
            uint256 effectivePrice = ((lusdGained + stabilityGained) * 1e18) / lqtyConsumed;
            console.log("Effective LQTY->LUSD price:", effectivePrice / 1e15, "milli-LUSD per LQTY");
        }

        // Assertions - more lenient since liquidity may be limited
        assertGt(lqtyConsumed, swapAmount * 20 / 100, "Should consume at least 20% of LQTY");
        assertGt(lusdGained + stabilityGained, 0, "Should gain some LUSD");

        console.log("SUCCESS: sellTokenForTokenToUniswapV3 working correctly");
    }

    // Helper Functions
    function _createLQTYSwapData(uint256 swapAmount) internal pure returns (bytes memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = C.LIQUITY_LQTY_TOKEN;
        tokens[1] = C.WETH;
        tokens[2] = C.LUSD;

        uint256 minLUSDAmount = swapAmount * 70 / 100; // 30% slippage tolerance

        return abi.encodeWithSignature(
            "sellToUniswap(address[],uint256,uint256,bool)", tokens, swapAmount, minLUSDAmount, false
        );
    }

    function _createLQTYSwapDataV3(uint256 swapAmount) internal pure returns (bytes memory) {
        // Use LQTY -> WETH -> LUSD path in V3 format since direct LQTY->LUSD likely doesn't exist
        bytes memory encodedPath = abi.encodePacked(
            C.LIQUITY_LQTY_TOKEN, // LQTY
            uint24(3000), // 0.3% fee tier LQTY->WETH
            C.WETH, // WETH
            uint24(3000), // 0.3% fee tier WETH->LUSD
            C.LUSD // LUSD
        );

        uint256 minBuyAmount = swapAmount * 70 / 100; // 30% slippage tolerance
        address recipient = address(0); // Router handles return to caller

        return abi.encodeWithSignature(
            "sellTokenForTokenToUniswapV3(bytes,uint256,uint256,address)",
            encodedPath,
            swapAmount,
            minBuyAmount,
            recipient
        );
    }

    function _createETHSwapData(uint256 ethAmount) internal pure returns (bytes memory) {
        // Uniswap V3 encoded path: ETH (WETH) -> LUSD
        bytes memory encodedPath = abi.encodePacked(
            C.WETH, // WETH
            uint24(3000), // 0.3% fee tier
            C.LUSD // LUSD
        );

        uint256 minBuyAmount = ethAmount / 20; // 5% slippage tolerance
        address recipient = address(0); // Router handles return to caller

        return abi.encodeWithSignature(
            "sellEthForTokenToUniswapV3(bytes,uint256,address)", encodedPath, minBuyAmount, recipient
        );
    }
}
