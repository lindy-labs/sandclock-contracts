// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/**
 * @title ERC4626StreamHub
 * @dev This contract implements a stream hub for managing yield streams between senders and receivers.
 * It allows users to open yield streams, claim yield from streams, and close streams to withdraw remaining shares.
 * The contract uses the ERC4626 interface for interacting with the underlying vault.
 */
contract ERC4626StreamHub is Multicall {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    error NotEnoughShares();
    error ZeroShares();
    error AddressZero();
    error CannotOpenStreamToSelf();
    error StreamDoesNotExist();
    error NoYieldToClaim();
    error InputParamsLengthMismatch();

    event Deposit(address indexed depositor, uint256 shares);
    event Withdraw(address indexed depositor, uint256 shares);
    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 yield);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares);

    IERC4626 public immutable vault;

    // receiver to number of shares it is entitled to as the yield beneficiary
    mapping(address => uint256) public receiverShares;

    // receiver to total amount of assets (principal) - not claimable
    mapping(address => uint256) public receiverTotalPrincipal;

    // receiver to total amount of assets (principal) allocated from a single address
    mapping(address => mapping(address => uint256)) public receiverPrincipal;

    constructor(IERC4626 _vault) {
        vault = _vault;
        IERC20(vault.asset()).safeApprove(address(vault), type(uint256).max);
    }

    /**
     * @dev Opens a yield stream for a specific receiver with a given number of shares.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate for the yield stream.
     */
    function openYieldStream(address _receiver, uint256 _shares) public {
        _checkZeroAddress(_receiver);
        _checkReceiver(_receiver);
        _checkZeroShares(_shares);

        vault.safeTransferFrom(msg.sender, address(this), _shares);

        uint256 principal = _convertToAssets(_shares);

        // balanceOf[msg.sender] -= _shares;
        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += principal;
        receiverPrincipal[_receiver][msg.sender] += principal;

        emit OpenYieldStream(msg.sender, _receiver, _shares, principal);
    }

    // TODO: do we need batch functions? same could be achieved using multicall
    /**
     * @dev Opens yield streams for multiple receivers with corresponding shares.
     * @param _receivers An array of receiver addresses.
     * @param _shares An array of share amounts corresponding to each receiver.
     */
    function openYieldStreamBatch(address[] calldata _receivers, uint256[] calldata _shares) external {
        if (_receivers.length != _shares.length) revert InputParamsLengthMismatch();

        for (uint256 i = 0; i < _receivers.length; i++) {
            openYieldStream(_receivers[i], _shares[i]);
        }
    }

    /**
     * @dev Closes a yield stream for a specific receiver.
     * If there is any yield to claim for the stream, it will remain unclaimed until the receiver calls `claimYield` function.
     * @param _receiver The address of the receiver.
     */
    function closeYieldStream(address _receiver) public {
        uint256 principal = receiverPrincipal[_receiver][msg.sender];

        if (principal == 0) revert StreamDoesNotExist();

        // asset amount of equivalent shares
        uint256 ask = _convertToShares(principal);
        uint256 totalPrincipal = receiverTotalPrincipal[_receiver];
        // the maximum amount of shares that can be attributed to the sender
        uint256 have = receiverShares[_receiver].mulDivDown(principal, totalPrincipal);

        // if there was a loss, withdraw the percentage of the shares
        // equivalent to the sender share of the total principal
        uint256 shares = ask > have ? have : ask;

        // update state and transfer
        receiverPrincipal[_receiver][msg.sender] = 0;
        receiverTotalPrincipal[_receiver] -= totalPrincipal;
        receiverShares[_receiver] -= shares;

        vault.safeTransfer(msg.sender, shares);

        emit CloseYieldStream(msg.sender, _receiver, shares);
    }

    /**
     * @dev Closes multiple yield streams for multiple receivers from the same streamer.
     * If there is any yield to claim for the stream, it will remain unclaimed until the receiver calls `claimYield` function.
     * @param _tos The array of receiver addresses.
     */
    function closeYieldStreamBatch(address[] calldata _tos) external {
        for (uint256 i = 0; i < _tos.length; i++) {
            closeYieldStream(_tos[i]);
        }
    }

    /**
     * @dev Claims the yield for the sender and transfers it to the specified receiver address.
     * @param _to The address to receive the claimed yield.
     * @return assets The amount of assets (tokens) claimed as yield.
     */
    function claimYield(address _to) external returns (uint256 assets) {
        _checkZeroAddress(_to);

        uint256 principalInShares = _convertToShares(receiverTotalPrincipal[msg.sender]);
        uint256 shares = receiverShares[msg.sender];

        // if vault made a loss, there is no yield to claim
        if (shares <= principalInShares) revert NoYieldToClaim();

        uint256 yieldShares = shares - principalInShares;

        receiverShares[msg.sender] -= yieldShares;

        assets = vault.redeem(yieldShares, _to, address(this));

        emit ClaimYield(msg.sender, _to, assets);
    }

    /**
     * @dev Calculates the yield for a given receiver.
     * @param _receiver The address of the receiver.
     * @return The calculated yield.
     */
    function yieldFor(address _receiver) public view returns (uint256) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        return currentValue > principal ? currentValue - principal : 0;
    }

    function _checkZeroAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert AddressZero();
    }

    function _checkZeroShares(uint256 _shares) internal pure {
        if (_shares == 0) revert ZeroShares();
    }

    function _checkReceiver(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return vault.convertToAssets(_shares);
    }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        return vault.convertToShares(_assets);
    }
}
