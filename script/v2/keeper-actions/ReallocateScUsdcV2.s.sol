// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {ScUsdcV2ScriptBase} from "../../base/ScUsdcV2ScriptBase.sol";
import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {PriceConverter} from "../../../src/steth/priceConverter/PriceConverter.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scCrossAssetYieldVault} from "../../../src/steth/scCrossAssetYieldVault.sol";

/**
 * A script for executing reallocate functionality for scUsdcV2 vaults.
 */
contract ReallocateScUsdcV2 is ScUsdcV2ScriptBase {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the reallocate script. The goal is to move funds from one lending protocol to another without touching the invested WETH.
    // @note: supply and withdraw amounts have to sum up to 0, same for borrow and repay amounts or else the script will revert
    // use adapter - whether or not to use a specific adapter
    // allocationPercent - the percentage of the total assets used as collateral to be allocated to the protocol adapter

    uint256 flashloanFeePercent = 0e18; // currently 0% on balancer

    bool public useMorpho = true;
    uint256 public morphoAllocationPercent = 0;

    bool public useAaveV2 = true;
    uint256 aaveV2AllocationPercent = 0;

    bool public useAaveV3 = false;
    uint256 public aaveV3AllocationPercent = 0;

    /*//////////////////////////////////////////////////////////////*/

    struct ReallocateData {
        uint256 adapterId;
        uint256 supplyAmount;
        uint256 borrowAmount;
        uint256 withdrawAmount;
        uint256 repayAmount;
    }

    // script state
    ReallocateData[] public reallocateData;
    bytes[] multicallData;
    uint256 flashLoanAmount;
    uint256 totalAllocationPercent;

    function run() external {
        console2.log("--ReallocateScUsdcV2 script running--");
        require(scUsdcV2.hasRole(scUsdcV2.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _logScriptParams();

        _logPositions("\tbefore reallocate");
        _initReallocateData();
        _createMulticallData();

        vm.startBroadcast(keeper);

        console2.log("start execution");

        scUsdcV2.reallocate(flashLoanAmount, multicallData);

        vm.stopBroadcast();

        _logPositions("\tafter reallocate");
        console2.log("--ReallocateScUsdcV2 script done--");
    }

    function _logPositions(string memory message) internal view {
        console2.log(message);

        console2.log("moprhoCollateral\t", morphoAdapter.getCollateral(address(scUsdcV2)));
        console2.log("moprhoDebt\t\t", morphoAdapter.getDebt(address(scUsdcV2)));

        console2.log("aaveV2Collateral\t", aaveV2Adapter.getCollateral(address(scUsdcV2)));
        console2.log("aaveV2Debt\t\t", aaveV2Adapter.getDebt(address(scUsdcV2)));

        console2.log("aaveV3Collateral\t", aaveV3Adapter.getCollateral(address(scUsdcV2)));
        console2.log("aaveV3Debt\t\t", aaveV3Adapter.getDebt(address(scUsdcV2)));
    }

    function _initReallocateData() internal {
        if (useMorpho) {
            if (!scUsdcV2.isSupported(morphoAdapter.id())) revert("morpho adapter not supported");

            _createData(morphoAdapter.id(), morphoAllocationPercent);

            totalAllocationPercent += morphoAllocationPercent;
        }

        if (useAaveV2) {
            if (!scUsdcV2.isSupported(aaveV2Adapter.id())) revert("aave v2 adapter not supported");

            _createData(aaveV2Adapter.id(), aaveV2AllocationPercent);

            totalAllocationPercent += aaveV2AllocationPercent;
        }

        if (useAaveV3) {
            if (!scUsdcV2.isSupported(aaveV3Adapter.id())) revert("aave v3 adapter not supported");

            _createData(aaveV3Adapter.id(), aaveV3AllocationPercent);

            totalAllocationPercent += aaveV3AllocationPercent;
        }

        if (totalAllocationPercent != 1e18) {
            revert("total allocation percent not 100%");
        }
    }

    function _createData(uint256 _adapterId, uint256 _allocationPercent) internal {
        ReallocateData memory data;

        data.adapterId = _adapterId;

        uint256 currentAllocation = scUsdcV2.getCollateral(_adapterId);
        uint256 expectedAllocation = scUsdcV2.totalCollateral().mulWadUp(_allocationPercent);
        uint256 currentDebt = scUsdcV2.getDebt(_adapterId);
        uint256 expectedDebt = scUsdcV2.totalDebt().mulWadUp(_allocationPercent);

        if (currentAllocation > expectedAllocation) {
            // we need to withdraw some collateral
            data.withdrawAmount = currentAllocation - expectedAllocation;
            data.repayAmount = currentDebt - expectedDebt;
        } else if (currentAllocation < expectedAllocation) {
            // we need to supply some collateral
            data.supplyAmount = expectedAllocation - currentAllocation;
            data.borrowAmount = expectedDebt - currentDebt;
        }

        reallocateData.push(data);
    }

    function _createMulticallData() internal {
        for (uint256 i = 0; i < reallocateData.length; i++) {
            ReallocateData memory data = reallocateData[i];

            if (data.withdrawAmount > 0) {
                flashLoanAmount += data.repayAmount;

                multicallData.push(
                    abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, data.adapterId, data.repayAmount)
                );
                multicallData.push(
                    abi.encodeWithSelector(
                        scCrossAssetYieldVault.withdraw.selector, data.adapterId, data.withdrawAmount
                    )
                );
            }
        }

        for (uint256 i = 0; i < reallocateData.length; i++) {
            ReallocateData memory data = reallocateData[i];

            if (data.supplyAmount > 0) {
                uint256 borrowAmount = data.borrowAmount.mulWadDown(1e18 - flashloanFeePercent);

                multicallData.push(
                    abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, data.adapterId, data.supplyAmount)
                );
                multicallData.push(
                    abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, data.adapterId, borrowAmount)
                );
            }
        }
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("flashloanFeePercent\t", flashloanFeePercent);
        console2.log("useMorpho\t\t", useMorpho);
        console2.log("morphoAllocationPercent\t", morphoAllocationPercent);
        console2.log("useAaveV2\t\t", useAaveV2);
        console2.log("aaveV2AllocationPercent\t", aaveV2AllocationPercent);
        console2.log("useAaveV3\t\t", useAaveV3);
        console2.log("aaveV3AllocationPercent\t", aaveV3AllocationPercent);
    }
}
