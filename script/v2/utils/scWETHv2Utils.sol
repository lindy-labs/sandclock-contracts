// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "../../base/CREATE3Script.sol";
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
import {MorphoAaveV3ScWethAdapter as scWethMorphoAdapter} from
    "../../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter as scWethCompoundV3Adapter} from
    "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";

/**
 * Contract containing the base methods required by all scWETHv2 scripts
 */
contract scWETHv2Utils is CREATE3Script {
    using FixedPointMathLib for uint256;

    scWETHv2 vault = scWETHv2(payable(vm.envAddress("scWETHv2")));
    PriceConverter priceConverter = PriceConverter(vm.envAddress("PRICE_CONVERTER"));
    scWETHv2Helper vaultHelper = scWETHv2Helper(vm.envAddress("scWETHv2Helper"));

    IAdapter morphoAdapter = IAdapter(vm.envAddress('scWETHv2_MORPHO_ADAPTER'));
    IAdapter compoundV3Adapter = IAdapter(vm.envAddress('scWETHv2_COMPOUND_ADAPTER'));

    uint256 morphoAdapterId;
    uint256 compoundV3AdapterId;

    mapping(IAdapter => uint256) targetLtv;

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    /// @dev invest the float lying in the vault to morpho and compoundV3
    function _invest(uint256 _amount, uint256 _morphoAllocationPercent, uint256 _compoundAllocationPercent) internal {
        uint256 investAmount = _amount - vault.minimumFloatAmount();

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount, _morphoAllocationPercent, _compoundAllocationPercent);

        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken
    /// @dev : NOTE: ASSUMING ZERO BALANCER FLASH LOAN FEES
    function _getInvestParams(uint256 _amount, uint256 _morphoAllocation, uint256 _compoundAllocation)
        internal
        view
        returns (bytes[] memory, uint256, uint256)
    {
        require(_morphoAllocation + _compoundAllocation == 1e18, "allocationPercents dont add up to 100%");

        uint256 investAmount = _amount;
        uint256 stEthRateTolerance = 0.999e18;

        uint256 morphoAmount = investAmount.mulWadDown(_morphoAllocation);
        uint256 compoundAmount = investAmount.mulWadDown(_compoundAllocation);

        uint256 morphoFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(morphoAdapter, morphoAmount);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);

        uint256 morphoSupplyAmount =
            priceConverter.ethToWstEth(morphoAmount + morphoFlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            priceConverter.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 totalFlashLoanAmount = morphoFlashLoanAmount + compoundFlashLoanAmount;

        bytes[] memory callData = new bytes[](3);

        callData[0] = abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, investAmount + totalFlashLoanAmount);

        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, morphoAdapterId, morphoSupplyAmount, morphoFlashLoanAmount
        );
        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, compoundV3AdapterId, compoundSupplyAmount, compoundFlashLoanAmount
        );

        return (callData, morphoSupplyAmount + compoundSupplyAmount, totalFlashLoanAmount);
    }

    // function _simulate_stEthStakingInterest(uint256 _timePeriod, uint256 _stEthStakingInterest) internal {
    //     // fast forward time to simulate supply and borrow interests
    //     vm.warp(block.timestamp + _timePeriod);
    //     uint256 prevBalance = _read_storage_uint(C.STETH, keccak256(abi.encodePacked("lido.Lido.beaconBalance")));
    //     vm.store(
    //         C.STETH,
    //         keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
    //         bytes32(prevBalance.mulWadDown(_stEthStakingInterest))
    //     );
    // }

    // function _read_storage_uint(address _addr, bytes32 _key) internal view returns (uint256) {
    //     return abi.decode(abi.encode(vm.load(_addr, _key)), (uint256));
    // }

    function _calcSupplyBorrowFlashLoanAmount(IAdapter _adapter, uint256 _amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(_adapter.id());
        uint256 collateral = vaultHelper.getCollateralInWeth(_adapter);

        uint256 target = targetLtv[_adapter].mulWadDown(_amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[_adapter]);
    }

    // function _fork(uint256 _blockNumber) internal {
    //     mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
    //     vm.selectFork(mainnetFork);
    //     vm.rollFork(_blockNumber);
    // }
}
