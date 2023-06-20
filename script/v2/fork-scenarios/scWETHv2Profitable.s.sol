// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {CREATE3Script} from "../../base/CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../../src/sc4626.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {AaveV3Adapter as scWethAaveV3Adapter} from "../../../src/steth/scWethV2-adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter as scWethCompoundV3Adapter} from "../../../src/steth/scWethV2-adapters/CompoundV3Adapter.sol";
import {AaveV3Adapter as scUsdcAaveV3Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3Adapter.sol";
import {AaveV2Adapter as scUsdcAaveV2Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2Adapter.sol";
import {MainnetDepolyBase} from "../../base/MainnetDepolyBase.sol";

/**
 * deploys scWETHv2 vault
 * deposits 100 ether to the vault
 * invests that 100 ether to aaveV3 and compoundV3 with allocation percents of 30% and 70% resp.
 * then simulates supply and borrow interest (by moving forward in time) and Lido staking interest at 7% (by changing Lido storage variables)
 * forge script script/v2/fork-scenarios/scWETHv2Profitable.s.sol --skip-simulation -vv
 */
contract scWETHv2SimulateProfits is MainnetDepolyBase, Test {
    uint256 mainnetFork;
    scWETHv2 vault;
    PriceConverter priceConverter;

    function run() external {
        fork(17243956);
        vm.startBroadcast(deployerAddress);

        deploy();
        depositToVault(100 ether);

        vm.stopBroadcast();
    }

    function fork(uint256 _blockNumber) internal {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(_blockNumber);
    }

    function deploy() internal {
        Swapper swapper = new Swapper();
        priceConverter = new PriceConverter(deployerAddress);

        vault = new scWETHv2(deployerAddress, keeper, 0.99e18, weth, swapper, priceConverter);

        addAdapters();
    }

    function addAdapters() internal {
        scWethAaveV3Adapter aaveV3Adapter = new scWethAaveV3Adapter();
        vault.addAdapter(aaveV3Adapter);

        scWethCompoundV3Adapter compoundV3Adapter = new scWethCompoundV3Adapter();
        vault.addAdapter(compoundV3Adapter);
    }

    function depositToVault(uint256 amount) internal {
        deal(address(weth), deployerAddress, amount);
        _deposit(vault, amount);
    }

    /// @dev invest the float lying in the vault to aaveV3 and compoundV3
    function invest(uint256 amount, uint256 aaveV3AllocationPercent, uint256 compoundAllocationPercent) internal {
        uint256 investAmount = amount - vault.minimumFloatAmount();

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) =
            getInvestParams(investAmount, aaveV3AllocationPercent, compoundAllocationPercent);

        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken
    /// @dev : NOTE: ASSUMING ZERO BALANCER FLASH LOAN FEES
    function getInvestParams(uint256 amount, uint256 aaveV3Allocation, uint256 compoundAllocation)
        internal
        view
        returns (bytes[] memory, uint256, uint256)
    {
        uint256 investAmount = amount;
        uint256 stEthRateTolerance = 0.999e18;

        uint256 aaveV3Amount = investAmount.mulWadDown(aaveV3Allocation);
        uint256 compoundAmount = investAmount.mulWadDown(compoundAllocation);

        uint256 aaveV3FlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(aaveV3Adapter, aaveV3Amount);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);

        uint256 aaveV3SupplyAmount =
            priceConverter.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            priceConverter.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 totalFlashLoanAmount = aaveV3FlashLoanAmount + compoundFlashLoanAmount;

        bytes[] memory callData = new bytes[](3);

        callData[0] = abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, investAmount + totalFlashLoanAmount);

        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, aaveV3AdapterId, aaveV3SupplyAmount, aaveV3FlashLoanAmount
        );
        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, compoundV3AdapterId, compoundSupplyAmount, compoundFlashLoanAmount
        );

        return (callData, aaveV3SupplyAmount + compoundSupplyAmount, totalFlashLoanAmount);
    }

    function _calcSupplyBorrowFlashLoanAmount(IAdapter adapter, uint256 amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(adapter.id());
        uint256 collateral = vaultHelper.getCollateralInWeth(adapter);

        uint256 target = targetLtv[adapter].mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[adapter]);
    }
}
