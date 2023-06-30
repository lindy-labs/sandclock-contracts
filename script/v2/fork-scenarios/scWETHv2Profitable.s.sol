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
import {AaveV3Adapter as scWethAaveV3Adapter} from "../../../src/steth/scWethV2-adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter as scWethCompoundV3Adapter} from "../../../src/steth/scWethV2-adapters/CompoundV3Adapter.sol";
import {AaveV3Adapter as scUsdcAaveV3Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3Adapter.sol";
import {AaveV2Adapter as scUsdcAaveV2Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2Adapter.sol";
import {MainnetDeployBase} from "../../base/MainnetDeployBase.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";

/**
 * deploys scWETHv2 vault
 * deposits 100 ether to the vault
 * invests that 100 ether to aaveV3 and compoundV3 with allocation percents of 30% and 70% resp.
 * then simulates supply and borrow interest (by moving forward in time) and Lido staking interest at 7% (by changing Lido storage variables)
 * forge script script/v2/fork-scenarios/scWETHv2Profitable.s.sol --skip-simulation -vv
 */
contract scWETHv2SimulateProfits is MainnetDeployBase, Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;
    scWETHv2 vault;
    PriceConverter priceConverter;
    scWETHv2Helper vaultHelper;

    uint256 aaveV3AdapterId;
    uint256 compoundV3AdapterId;

    IAdapter aaveV3Adapter;
    IAdapter compoundV3Adapter;

    mapping(IAdapter => uint256) targetLtv;

    function run() external {
        fork(17529069);
        vm.startBroadcast(deployerAddress);

        deploy();
        depositToVault(100 ether);

        uint256 aaveV3AllocationPercent = 0.3e18;
        uint256 compoundV3AllocationPercent = 0.7e18;

        vm.stopBroadcast();

        vm.startBroadcast(keeper);
        invest(weth.balanceOf(address(vault)), aaveV3AllocationPercent, compoundV3AllocationPercent);
        vm.stopBroadcast();

        console.log("Assets before time skip", vault.totalAssets());

        // fast forward 365 days in time and simulate an annual staking interest of 7.1%
        simulate_stEthStakingInterest(365 days, 1.071e18);

        console.log("Assets after time skip", vault.totalAssets());
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
        vaultHelper = new scWETHv2Helper(vault, priceConverter);

        addAdapters();
    }

    function addAdapters() internal {
        aaveV3Adapter = new scWethAaveV3Adapter();
        aaveV3AdapterId = aaveV3Adapter.id();
        vault.addAdapter(aaveV3Adapter);
        targetLtv[aaveV3Adapter] = 0.8e18; // the target Ltv at which all subsequent aave deposits must be done

        compoundV3Adapter = new scWethCompoundV3Adapter();
        compoundV3AdapterId = compoundV3Adapter.id();
        vault.addAdapter(compoundV3Adapter);
        targetLtv[compoundV3Adapter] = 0.8e18; // the target Ltv at which all subsequent compound deposits must be done
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
        require(aaveV3Allocation + compoundAllocation == 1e18, "allocationPercents dont add up to 100%");

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

    function simulate_stEthStakingInterest(uint256 timePeriod, uint256 stEthStakingInterest) internal {
        // fast forward time to simulate supply and borrow interests
        vm.warp(block.timestamp + timePeriod);
        uint256 prevBalance = read_storage_uint(C.STETH, keccak256(abi.encodePacked("lido.Lido.beaconBalance")));
        vm.store(
            C.STETH,
            keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
            bytes32(prevBalance.mulWadDown(stEthStakingInterest))
        );
    }

    function read_storage_uint(address addr, bytes32 key) internal view returns (uint256) {
        return abi.decode(abi.encode(vm.load(addr, key)), (uint256));
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
