// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scCrossAssetYieldVaultBaseScript} from "./scCrossAssetYieldVaultBaseScript.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";

abstract contract scCrossAssetYieldVaultReallocateScript is scCrossAssetYieldVaultBaseScript {
    using FixedPointMathLib for uint256;

    struct ReallocateData {
        uint256 adapterId;
        uint256 allocationPercent;
        uint256 supplyAmount;
        uint256 borrowAmount;
        uint256 withdrawAmount;
        uint256 repayAmount;
    }

    uint256 flashloanFeePercent = 0e18; // currently 0% on balancer

    // script state
    ReallocateData[] public reallocateData;
    bytes[] multicallData;
    uint256 flashLoanAmount;

    function _initReallocateData() internal virtual;

    function run() external {
        console2.log("--reallocate script running--");
        require(vault.hasRole(vault.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _initReallocateData();
        _createMulticallData();
        _checkAllocationPercentages();

        _logScriptParams();
        _logPositions("before reallocate");

        vm.startBroadcast(keeper);

        vault.reallocate(flashLoanAmount, multicallData);

        vm.stopBroadcast();

        _logPositions("after reallocate");
        console2.log("--reallocate script done--");
    }

    function _logPositions(string memory _message) internal virtual;

    function _checkAllocationPercentages() internal view {
        uint256 totalAllocationPercent = 0;
        for (uint256 i = 0; i < reallocateData.length; i++) {
            totalAllocationPercent += reallocateData[i].allocationPercent;
        }

        if (totalAllocationPercent != 1e18) {
            revert("total allocation percent not 100%");
        }
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

    function _createData(uint256 _adapterId, uint256 _allocationPercent) internal {
        ReallocateData memory data;

        data.adapterId = _adapterId;
        data.allocationPercent = _allocationPercent;

        uint256 currentAllocation = vault.getCollateral(_adapterId);
        uint256 expectedAllocation = vault.totalCollateral().mulWadUp(_allocationPercent);
        uint256 currentDebt = vault.getDebt(_adapterId);
        uint256 expectedDebt = vault.totalDebt().mulWadUp(_allocationPercent);

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
}
