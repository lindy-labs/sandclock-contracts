// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {scWETHv2} from "./scWETHv2.sol";
import {Constants as C} from "../lib/Constants.sol";
import {ZeroAddress, ProtocolNotSupported} from "../errors/scErrors.sol";

/**
 * @title scWETHv2Keeper
 * @notice Manages the keeper role for the scWETHv2 contract, providing functions to rebalance, set targets, and calculate investment parameters.
 * @dev Utilizes AccessControl for role-based access management.
 *
 * ## Key Features
 * - **Rebalance Execution:** Allows authorized operators to execute rebalance operations on the scWETHv2 contract.
 * - **Target Management:** Enables admin to update the target scWETHv2 contract.
 * - **Operator Management:** Admin can assign or change the operator role.
 * - **Investment Parameter Calculation:** Calculates parameters for rebalancing investments among supported adapters.
 *
 * ## Roles
 * - `DEFAULT_ADMIN_ROLE`: Manages target contract updates and operator assignments.
 * - `OPERATOR_ROLE`: Authorized to execute rebalances and manage leftover wstETH.
 *
 * ## Security Considerations
 * - **Input Validation:** Ensures all input parameters are valid and within acceptable ranges.
 * - **Role-Based Access Control:** Restricts critical functions to authorized roles only.
 *
 * ## Usage
 * Admins can update the target contract and assign operators. Operators can execute rebalances and manage investments according to the calculated parameters.
 */
contract scWETHv2Keeper is AccessControl {
    using FixedPointMathLib for uint256;

    error NoNeedToInvest();
    error InvalidInputParameters();
    error ZeroAllocation();
    error AllocationsMustSumToOne();
    error ZeroTargetLtv();

    /**
     * @notice Emitted when the target scWETHv2 vault contract is updated.
     * @param admin The address of the admin who updated the target.
     * @param newTarget The new target address.
     */
    event TargetUpdated(address indexed admin, address newTarget);

    /**
     * @notice Emitted when the operator is changed.
     * @param admin The address of the admin who changed the operator.
     * @param oldOperator The address of the old operator.
     * @param newOperator The address of the new operator.
     */
    event OperatorChanged(address indexed admin, address indexed oldOperator, address indexed newOperator);

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    IERC20 public constant wstEth = IERC20(C.WSTETH);

    /// @notice The target scWETHv2 contract.
    scWETHv2 public target;

    /**
     * @notice Initializes the scWETHv2Keeper contract.
     * @dev Initializes the contract with the target, admin, and operator addresses, and grants roles accordingly.
     * @param _target The target scWETHv2 contract.
     * @param _admin The address of the admin.
     * @param _operator The address of the operator.
     *
     * @custom:requirements
     * - `_target` must not be the zero address.
     * - `_admin` must not be the zero address.
     * - `_operator` must not be the zero address.
     *
     * @custom:reverts
     * - `ZeroAddress` if any of the provided addresses are zero.
     */
    constructor(scWETHv2 _target, address _admin, address _operator) {
        _zeroAddressCheck(address(_target));
        _zeroAddressCheck(_admin);
        _zeroAddressCheck(_operator);

        target = _target;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
    }

    /**
     * @notice Sets the target scWETHv2 contract.
     * @dev Only callable by an account with the DEFAULT_ADMIN_ROLE.
     * @param _target The new target scWETHv2 contract.
     *
     * @custom:requirements
     * - `_target` must not be the zero address.
     * - Caller must have the `DEFAULT_ADMIN_ROLE`.
     *
     * @custom:reverts
     * - `ZeroAddress` if the new target address is zero.
     * - `AccessControlUnauthorizedAccount` if the caller does not have the `DEFAULT_ADMIN_ROLE`.
     *
     * @custom:emits
     * - Emits {TargetUpdated} event upon successful target update.
     */
    function setTarget(scWETHv2 _target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _zeroAddressCheck(address(_target));

        target = _target;

        emit TargetUpdated(msg.sender, address(_target));
    }

    /**
     * @notice Changes the operator of the contract.
     * @dev Only callable by an account with the DEFAULT_ADMIN_ROLE.
     * @param _from The address of the current operator.
     * @param _to The address of the new operator.
     *
     * @custom:requirements
     * - `_to` must not be the zero address.
     * - `_from` must not be the zero address.
     * - Caller must have the `DEFAULT_ADMIN_ROLE`.
     *
     * @custom:reverts
     * - `ZeroAddress` if the new operator address is zero or the current operator address is zero.
     * - `AccessControlUnauthorizedAccount` if the caller does not have the `DEFAULT_ADMIN_ROLE`.
     *
     * @custom:emits
     * - Emits {OperatorChanged} event upon successful operator change.
     */
    function changeOperator(address _from, address _to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _zeroAddressCheck(_to);
        _zeroAddressCheck(_from);

        _revokeRole(OPERATOR_ROLE, _from);
        _grantRole(OPERATOR_ROLE, _to);

        emit OperatorChanged(msg.sender, _from, _to);
    }

    /**
     * @notice Executes a rebalance operation on the target scWETHv2 contract.
     * @dev Only callable by an account with the OPERATOR_ROLE. This function rebalances the investments, and if there is any leftover wstETH, it supplies it to the specified adapter.
     * @param _flashLoanAmount The amount to be flashloaned.
     * @param _multicallData The array of encoded function calls to be executed.
     * @param _adapterIdForLeftoverWstEth The adapter ID to which leftover wstETH will be supplied.
     *
     * @custom:requirements
     * - `_adapterIdForLeftoverWstEth` must be a supported adapter ID.
     * - Caller must have the `OPERATOR_ROLE`.
     *
     * @custom:reverts
     * - `NoNeedToInvest` if the current float is less than the minimum required float.
     * - `ProtocolNotSupported` if the specified adapter ID is not supported.
     * - `AccessControlUnauthorizedAccount` if the caller does not have the `OPERATOR_ROLE`.
     *
     * @custom:emits
     * - Emits events from the `target.rebalance` and `target.supplyAndBorrow` functions.
     */
    function invest(uint256 _flashLoanAmount, bytes[] calldata _multicallData, uint256 _adapterIdForLeftoverWstEth)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (!target.isSupported(_adapterIdForLeftoverWstEth)) {
            revert ProtocolNotSupported(_adapterIdForLeftoverWstEth);
        }

        target.rebalance(_calculateInvestAmount(), _flashLoanAmount, _multicallData);

        uint256 wstEthBalance = wstEth.balanceOf(address(target));

        if (wstEthBalance != 0) target.supplyAndBorrow(_adapterIdForLeftoverWstEth, wstEthBalance, 1);
    }

    /**
     * @notice Calculates the investment parameters for rebalancing.
     * @dev This function performs various checks on the input parameters and calculates the necessary amounts for rebalancing.
     * @param _adapterIds The array of adapter IDs.
     * @param _allocations The array of allocations corresponding to each adapter ID.
     * @param _targetLtvs The array of target LTVs corresponding to each adapter ID.
     * @return totalInvestAmount The total amount to invest.
     * @return totalFlashLoanAmount The total amount to flashloan.
     * @return rebalanceMulticallData The array of encoded function calls for the rebalance operation.
     *
     * @custom:requirements
     * - `_adapterIds`, `_allocations`, and `_targetLtvs` must have the same length and must not be empty.
     * - `_allocations` must sum to one.
     * - Each `_allocation` must be non-zero.
     * - Each `_targetLtv` must be non-zero.
     * - Each `_adapterId` must be supported by the target contract.
     *
     * @custom:reverts
     * - `NoNeedToInvest` if the current float is less than the minimum required float.
     * - `InvalidInputParameters` if the lengths of the input arrays are not equal or are zero.
     * - `ZeroAllocation` if any of the allocations is zero.
     * - `AllocationsMustSumToOne` if the total allocation does not sum to one.
     * - `ProtocolNotSupported` if any of the specified adapter IDs is not supported.
     * - `ZeroTargetLtv` if any of the target LTVs is zero.
     */
    function calculateInvestParams(
        uint256[] calldata _adapterIds,
        uint256[] calldata _allocations,
        uint256[] calldata _targetLtvs
    )
        external
        view
        returns (uint256 totalInvestAmount, uint256 totalFlashLoanAmount, bytes[] memory rebalanceMulticallData)
    {
        if (
            _adapterIds.length == 0 || _adapterIds.length != _allocations.length
                || _adapterIds.length != _targetLtvs.length
        ) {
            revert InvalidInputParameters();
        }

        uint256 totalAllocation;
        for (uint256 i = 0; i < _allocations.length; i++) {
            if (_allocations[i] == 0) revert ZeroAllocation();
            totalAllocation += _allocations[i];
        }

        if (totalAllocation != C.ONE) revert AllocationsMustSumToOne();

        rebalanceMulticallData = new bytes[](_adapterIds.length + 1); // +1 for swapWethToWstEth
        // start at 1 because the first call is for swapping WETH to wstETH
        uint256 callDataIndex = 1;
        totalInvestAmount = _calculateInvestAmount();

        for (uint256 i = 0; i < _adapterIds.length; i++) {
            uint256 adapterId = _adapterIds[i];
            uint256 allocation = _allocations[i];
            uint256 targetLtv = _targetLtvs[i];

            if (!target.isSupported(adapterId)) revert ProtocolNotSupported(adapterId);

            if (targetLtv == 0) revert ZeroTargetLtv();

            uint256 investAmount = totalInvestAmount.mulWadDown(allocation);

            uint256 flashLoanAmount = investAmount.divWadDown(C.ONE - targetLtv) - investAmount;
            totalFlashLoanAmount += flashLoanAmount;

            uint256 supplyWstEthAmount = target.priceConverter().ethToWstEth(investAmount + flashLoanAmount);

            rebalanceMulticallData[callDataIndex] =
                abi.encodeCall(scWETHv2.supplyAndBorrow, (callDataIndex, supplyWstEthAmount, flashLoanAmount));
            callDataIndex++;
        }

        rebalanceMulticallData[0] = abi.encodeCall(scWETHv2.swapWethToWstEth, totalInvestAmount + totalFlashLoanAmount);
    }

    function _calculateInvestAmount() internal view returns (uint256) {
        uint256 float = target.asset().balanceOf(address(target));
        uint256 minRequiredFloat = target.minimumFloatAmount();

        if (minRequiredFloat >= float) revert NoNeedToInvest();

        return float - minRequiredFloat;
    }

    function _zeroAddressCheck(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }
}
