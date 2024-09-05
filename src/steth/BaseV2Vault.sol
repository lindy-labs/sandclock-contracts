// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {TokenOutNotAllowed, AmountReceivedBelowMin} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {ProtocolNotSupported, ProtocolInUse, ZeroAddress} from "../errors/scErrors.sol";
import {Constants as C} from "../lib/Constants.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {IAdapter} from "./IAdapter.sol";
import {sc4626} from "../sc4626.sol";
import {IPriceConverter} from "./priceConverter/IPriceConverter.sol";
import {ISwapper} from "./swapper/ISwapper.sol";

/**
 * @title BaseV2Vault
 * @notice Base vault contract for v2 vaults to that use multiple lending markets thru adapters.
 */
abstract contract BaseV2Vault is sc4626, IFlashLoanRecipient {
    using Address for address;
    using SafeTransferLib for ERC20;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    event SwapperUpdated(address indexed admin, address newSwapper);
    event PriceConverterUpdated(address indexed admin, address newPriceConverter);
    event ProtocolAdapterAdded(address indexed admin, uint256 adapterId, address adapter);
    event ProtocolAdapterRemoved(address indexed admin, uint256 adapterId);
    event RewardsClaimed(uint256 adapterId);
    event TokenSwapped(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutReceived);
    event TokenWhitelisted(address token, bool value);

    // Balancer vault for flashloans
    IVault public constant balancerVault = IVault(C.BALANCER_VAULT);

    // price converter contract
    IPriceConverter public priceConverter;

    // swapper contract for facilitating token swaps
    ISwapper public swapper;

    // mapping of IDs to lending protocol adapter contracts
    EnumerableMap.UintToAddressMap internal protocolAdapters;

    // mapping for the tokenOuts allowed during zeroExSwap
    mapping(ERC20 => bool) internal zeroExSwapWhitelist;

    constructor(
        address _admin,
        address _keeper,
        ERC20 _asset,
        IPriceConverter _priceConverter,
        ISwapper _swapper,
        string memory _name,
        string memory _symbol
    ) sc4626(_admin, _keeper, _asset, _name, _symbol) {
        _setPriceConverter(_priceConverter);
        _setSwapper(_swapper);

        zeroExSwapWhitelist[_asset] = true;
    }

    /**
     * @notice whitelist (or cancel whitelist) a token to be swapped out using zeroExSwap
     * @param _token The token to whitelist
     * @param _value whether to whitelist or cancel whitelist
     */
    function whiteListOutToken(ERC20 _token, bool _value) external {
        _onlyAdmin();

        if (address(_token) == address(0)) revert ZeroAddress();

        zeroExSwapWhitelist[_token] = _value;

        emit TokenWhitelisted(address(_token), _value);
    }

    /**
     * @notice Set the swapper contract used for executing token swaps.
     * @param _newSwapper The new swapper contract.
     */
    function setSwapper(ISwapper _newSwapper) external {
        _onlyAdmin();

        _setSwapper(_newSwapper);

        emit SwapperUpdated(msg.sender, address(_newSwapper));
    }

    /**
     * @notice Set the price converter contract used for executing token swaps.
     * @param _newPriceConverter The new price converter contract.
     */
    function setPriceConverter(IPriceConverter _newPriceConverter) external {
        _onlyAdmin();

        _setPriceConverter(_newPriceConverter);

        emit PriceConverterUpdated(msg.sender, address(_newPriceConverter));
    }

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

    /// @notice returns the adapter address given the adapterId (only if the adaapterId is supported else returns zero address)
    /// @param _adapterId the id of the adapter to check
    function getAdapter(uint256 _adapterId) external view returns (address adapter) {
        (, adapter) = protocolAdapters.tryGet(_adapterId);
    }

    /**
     * @notice returns whether a token is whitelisted to be swapped out using zeroExSwap or not
     */
    function isTokenWhitelisted(ERC20 _token) external view returns (bool) {
        return zeroExSwapWhitelist[_token];
    }

    /**
     * @notice Claim rewards from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _callData The encoded data for the claimRewards function.
     */
    function claimRewards(uint256 _adapterId, bytes calldata _callData) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.claimRewards.selector, _callData));

        emit RewardsClaimed(_adapterId);
    }

    /**
     * @notice Sell any token for any whitelisted token on preconfigured exchange in the swapper contract.
     * @param _tokenIn Address of the token to swap.
     * @param _tokenOut Address of the token to receive.
     * @param _amountIn Amount of the token to swap.
     * @param _amountOutMin Minimum amount of the token to receive.
     * @param _swapData Arbitrary data to pass to the swap router.
     */
    function swapTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) external {
        _onlyKeeperOrFlashLoan();

        if (!zeroExSwapWhitelist[ERC20(_tokenOut)]) revert TokenOutNotAllowed(_tokenOut);

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                ISwapper.swapTokens.selector, _tokenIn, _tokenOut, _amountIn, _amountOutMin, _swapData
            )
        );

        uint256 amountReceived = abi.decode(result, (uint256));

        emit TokenSwapped(_tokenIn, _tokenOut, _amountIn, amountReceived);
    }

    function _multiCall(bytes[] memory _callData) internal {
        for (uint256 i = 0; i < _callData.length; i++) {
            if (_callData[i].length == 0) continue;

            address(this).functionDelegateCall(_callData[i]);
        }
    }

    function _adapterDelegateCall(uint256 _adapterId, bytes memory _data) internal {
        protocolAdapters.get(_adapterId).functionDelegateCall(_data);
    }

    function _adapterDelegateCall(address _adapter, bytes memory _data) internal {
        _adapter.functionDelegateCall(_data);
    }

    function _setSwapper(ISwapper _newSwapper) internal {
        _zeroAddressCheck(address(_newSwapper));

        swapper = _newSwapper;
    }

    function _setPriceConverter(IPriceConverter _newPriceConverter) internal {
        _zeroAddressCheck(address(_newPriceConverter));

        priceConverter = _newPriceConverter;
    }

    function _isSupportedCheck(uint256 _adapterId) internal view {
        if (!isSupported(_adapterId)) revert ProtocolNotSupported(_adapterId);
    }

    function _zeroAddressCheck(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }
}
