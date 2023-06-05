// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ProtocolNotSupported, ProtocolInUse} from "../errors/scErrors.sol";

import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";

import {IAdapter} from "./IAdapter.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {Swapper} from "./Swapper.sol";
import {sc4626} from "../sc4626.sol";

abstract contract AdapterVault is sc4626 {
    using Address for address;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    event ProtocolAdapterAdded(address indexed admin, uint256 adapterId, address adapter);
    event ProtocolAdapterRemoved(address indexed admin, uint256 adapterId);
    event RewardsClaimed(uint256 adapterId);

    // mapping of IDs to lending protocol adapter contracts
    EnumerableMap.UintToAddressMap internal protocolAdapters;

    /**
     * @notice Add a new protocol adapter to the vault.
     * @param _adapter The adapter to add.
     */
    function addAdapter(IAdapter _adapter) external {
        _onlyAdmin();

        uint256 id = _adapter.id();

        if (isSupported(id)) revert ProtocolInUse(id);

        protocolAdapters.set(id, address(_adapter));

        address(_adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));

        emit ProtocolAdapterAdded(msg.sender, id, address(_adapter));
    }

    /**
     * @notice Remove a protocol adapter from the vault. Reverts if the adapter is in use unless _force is true.
     * @param _adapterId The ID of the adapter to remove.
     * @param _force Whether or not to force the removal of the adapter.
     */
    function removeAdapter(uint256 _adapterId, bool _force) external {
        _onlyAdmin();
        _isSupportedCheck(_adapterId);

        // check if protocol is being used
        if (!_force && IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this)) > 0) {
            revert ProtocolInUse(_adapterId);
        }

        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.revokeApprovals.selector));

        protocolAdapters.remove(_adapterId);

        emit ProtocolAdapterRemoved(msg.sender, _adapterId);
    }

    /**
     * @notice Check if a lending market adapter is supported/used.
     * @param _adapterId The ID of the lending market adapter.
     */
    function isSupported(uint256 _adapterId) public view returns (bool) {
        return protocolAdapters.contains(_adapterId);
    }

    /**
     * @notice Claim rewards from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _callData The encoded data for the claimRewards function.
     */
    function claimRewards(uint256 _adapterId, bytes calldata _callData) external {
        _onlyKeeper();
        _isSupportedCheck(_adapterId);
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.claimRewards.selector, _callData));

        emit RewardsClaimed(_adapterId);
    }

    function _multiCall(bytes[] memory _callData) internal {
        for (uint256 i = 0; i < _callData.length; i++) {
            address(this).functionDelegateCall(_callData[i]);
        }
    }

    function _adapterDelegateCall(uint256 _adapterId, bytes memory _data) internal {
        protocolAdapters.get(_adapterId).functionDelegateCall(_data);
    }

    function _adapterDelegateCall(address _adapter, bytes memory _data) internal {
        _adapter.functionDelegateCall(_data);
    }

    function _isSupportedCheck(uint256 _adapterId) internal view {
        if (!isSupported(_adapterId)) revert ProtocolNotSupported(_adapterId);
    }
}
