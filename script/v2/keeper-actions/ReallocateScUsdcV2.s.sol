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
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";

/**
 * A script for executing rebalance functionality for scUsdcV2 vaults.
 */
contract ReallocateScUsdcV2 is ScUsdcV2ScriptBase {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the reallocate script. The goal is to move funds from one lending protocol to another without touching the invested WETH.
    // @note: supply and withdraw amounts have to sum up to 0, same for borrow and repay amounts or else the script will revert
    // use adapter - whether or not to use a specific adapter
    // supply amount - the amount of USDC that will be supplied to a specific lending protocol
    // borrow amount - the amount of WETH that will be borrowed from a specific lending protocol
    // withdraw amount - the amount of USDC that will be withdrawn from a specific lending protocol
    // repay amount - the amount of WETH that will be repaid to a specific lending protocol

    uint256 flashloanFeePercent = 0e18; // currently 0% on balancer

    bool public useMorpho = true;
    uint256 public morphoSupplyAmount = 0;
    uint256 public morphoBorrowAmount = 0;
    uint256 public morphoWithdrawAmount = 0;
    uint256 public morphoRepayAmount = 0;

    bool public useAaveV2 = true;
    uint256 public aaveV2SupplyAmount = 0;
    uint256 public aaveV2BorrowAmount = 0;
    uint256 public aaveV2WithdrawAmount = 0;
    uint256 public aaveV2RepayAmount = 0;

    bool public useAaveV3 = false;
    uint256 public aaveV3SupplyAmount = 0;
    uint256 public aaveV3BorrowAmount = 0;
    uint256 public aaveV3WithdrawAmount = 0;
    uint256 public aaveV3RepayAmount = 0;

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

    function run() external {
        console2.log("--ReallocateScUsdcV2 script running--");
        require(scUsdcV2.hasRole(scUsdcV2.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _logPositions("\tbefore reallocate");
        _initReallocateData();
        _createMulticallData();

        vm.startBroadcast(keeper);

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

            ReallocateData memory data;

            data.adapterId = morphoAdapter.id();
            data.supplyAmount = morphoSupplyAmount;
            data.borrowAmount = morphoBorrowAmount;
            data.withdrawAmount = morphoWithdrawAmount;
            data.repayAmount = morphoRepayAmount;

            reallocateData.push(data);
        }

        if (useAaveV2) {
            if (!scUsdcV2.isSupported(aaveV2Adapter.id())) revert("aave v2 adapter not supported");

            ReallocateData memory data;

            data.adapterId = aaveV2Adapter.id();
            data.supplyAmount = aaveV2SupplyAmount;
            data.borrowAmount = aaveV2BorrowAmount;
            data.withdrawAmount = aaveV2WithdrawAmount;
            data.repayAmount = aaveV2RepayAmount;

            reallocateData.push(data);
        }

        if (useAaveV3) {
            if (!scUsdcV2.isSupported(aaveV3Adapter.id())) revert("aave v3 adapter not supported");

            ReallocateData memory data;

            data.adapterId = aaveV3Adapter.id();
            data.supplyAmount = aaveV3SupplyAmount;
            data.borrowAmount = aaveV3BorrowAmount;
            data.withdrawAmount = aaveV3WithdrawAmount;
            data.repayAmount = aaveV3RepayAmount;

            reallocateData.push(data);
        }
    }

    function _createMulticallData() internal {
        int256 totalSupplyChange = 0;
        int256 totalDebtChange = 0;

        for (uint256 i = 0; i < reallocateData.length; i++) {
            ReallocateData memory data = reallocateData[i];

            if (data.withdrawAmount > 0) {
                flashLoanAmount += data.repayAmount;
                totalSupplyChange -= int256(data.withdrawAmount);
                totalDebtChange -= int256(data.repayAmount);

                multicallData.push(abi.encodeWithSelector(scUsdcV2.repay.selector, data.adapterId, data.repayAmount));
                multicallData.push(
                    abi.encodeWithSelector(scUSDCv2.withdraw.selector, data.adapterId, data.withdrawAmount)
                );
            }
        }

        for (uint256 i = 0; i < reallocateData.length; i++) {
            ReallocateData memory data = reallocateData[i];

            if (data.supplyAmount > 0) {
                uint256 borrowAmount = data.borrowAmount.mulWadDown(1e18 - flashloanFeePercent);

                totalSupplyChange += int256(data.supplyAmount);
                totalDebtChange += int256(data.borrowAmount);

                multicallData.push(abi.encodeWithSelector(scUsdcV2.supply.selector, data.adapterId, data.supplyAmount));
                multicallData.push(abi.encodeWithSelector(scUsdcV2.borrow.selector, data.adapterId, borrowAmount));
            }
        }

        if (totalSupplyChange != 0) {
            revert("total supply change != 0");
        }

        if (totalDebtChange != 0) {
            revert("total debt change != 0");
        }
    }
}
