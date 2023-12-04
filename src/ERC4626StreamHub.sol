// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

/**
 * @title ERC4626StreamHub
 * @dev This contract implements a stream hub for managing yield streams between senders and recipients.
 * It allows users to deposit shares or assets into the contract, open yield streams, claim yield from streams,
 * and close streams to withdraw remaining shares. The contract uses the ERC4626 interface for interacting with the vault.
 */
contract ERC4626StreamHub is Multicall {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    error NotEnoughShares();
    error ZeroShares();
    error InvalidReceiverAddress();
    error StreamDoesNotExist();
    error NoYieldToClaim();
    error InputParamsLengthMismatch();

    event Deposit(address indexed depositor, uint256 shares);
    event Withdraw(address indexed depositor, uint256 shares);
    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares);
    event ClaimYield(address indexed streamer, address indexed receiver, uint256 yield);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares);

    IERC4626 public immutable vault;

    mapping(address => uint256) public balanceOf;
    mapping(uint256 => YieldStream) public yieldStreams;
    // TODO: needed for frontend? ie should the frontend be able to query this to get all the streams for a given address?
    mapping(address => address[]) public receiverToDepositors;
    mapping(address => address[]) public depositorToReceivers;

    struct YieldStream {
        uint256 shares;
        uint256 principal;
    }

    constructor(IERC4626 _vault) {
        vault = _vault;
        IERC20(vault.asset()).safeApprove(address(vault), type(uint256).max);
    }

    /**
     * @dev Deposits a specified number of shares into the contract.
     * Increases the balance of the depositor and transfers the shares from the depositor's address to the contract's address.
     * @param _shares The number of shares to deposit.
     */
    function deposit(uint256 _shares) external {
        balanceOf[msg.sender] += _shares;
        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit Deposit(msg.sender, _shares);
    }

    /**
     * @dev Deposits a specified number of assets into the contract.
     * Transfers the assets from the depositor's address to the contract's address and mints the corresponding shares.
     * Increases the balance of the depositor by the number of shares minted.
     * @param _assets The number of assets to deposit.
     * @return shares The number of shares minted.
     */
    function depositAssets(uint256 _assets) external returns (uint256 shares) {
        IERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), _assets);

        shares = vault.deposit(_assets, address(this));
        balanceOf[msg.sender] += shares;

        emit Deposit(msg.sender, shares);
    }

    /**
     * @dev Withdraws a specified number of shares from the contract.
     * Decreases the balance of the withdrawer and transfers the shares from the contract's address to the withdrawer's address.
     * Shares allocated to yield streams cannot be withdrawn until the stream is closed.
     * @param _shares The number of shares to withdraw.
     */
    function withdraw(uint256 _shares) external {
        _checkSufficientShares(_shares);

        balanceOf[msg.sender] -= _shares;
        vault.safeTransfer(msg.sender, _shares);

        emit Withdraw(msg.sender, _shares);
    }

    /**
     * @dev Withdraws a specified number of assets from the contract.
     * Burns the corresponding shares and transfers the assets from the contract's address to the withdrawer's address.
     * Decreases the balance of the withdrawer by the number of shares burned.
     * Shares allocated to yield streams cannot be withdrawn until the stream is closed.
     * @param _assets The number of assets to withdraw.
     * @return shares The number of shares burned.
     */
    function withdrawAssets(uint256 _assets) external returns (uint256 shares) {
        shares = _withdrawFromVault(_assets, msg.sender);

        _checkSufficientShares(shares);
        balanceOf[msg.sender] -= shares;

        emit Withdraw(msg.sender, shares);
    }

    /**
     * @dev Opens a yield stream for a specific recipient with a given number of shares.
     * @param _to The address of the recipient.
     * @param _shares The number of shares to allocate for the yield stream.
     */
    function openYieldStream(address _to, uint256 _shares) external {
        _openYieldStream(_to, _shares);
    }

    // TODO: do we need batch functions? same could be achieved using multicall
    /**
     * @dev Opens yield streams for multiple recipients with corresponding shares.
     * @param _receivers An array of recipient addresses.
     * @param _shares An array of share amounts corresponding to each recipient.
     */
    function openYieldStreamBatch(address[] calldata _receivers, uint256[] calldata _shares) external {
        if (_receivers.length != _shares.length) revert InputParamsLengthMismatch();

        for (uint256 i = 0; i < _receivers.length; i++) {
            _openYieldStream(_receivers[i], _shares[i]);
        }
    }

    /**
     * @dev The caller must have sufficient shares.
     * @dev The recipient address must be valid.
     */
    function _openYieldStream(address _to, uint256 _shares) internal {
        _checkSufficientShares(_shares);
        _checkReceiverAddress(_to);

        balanceOf[msg.sender] -= _shares;

        YieldStream storage stream = yieldStreams[getStreamId(msg.sender, _to)];
        stream.shares += _shares;
        stream.principal += _convertToAssets(_shares);

        emit OpenYieldStream(msg.sender, _to, _shares);
    }

    /**
     * @dev Claims the yield for a single stream defined by `_from` to `_to` addresses.
     * @param _from The address of the sender of the stream.
     * @param _to The address of the recipient of the stream.
     */
    function claimYield(address _from, address _to) external {
        _claimYield(_from, _to);
    }

    /**
     * @dev Claims the yield for multiple streams in a batch.
     * @param _froms The array of addresses representing the senders of the streams.
     * @param _tos The array of addresses representing the recipients of the streams.
     * @notice The length of `_froms` and `_tos` arrays must be the same.
     */
    function claimYieldBatch(address[] calldata _froms, address[] calldata _tos) external {
        if (_froms.length != _tos.length) revert InputParamsLengthMismatch();

        for (uint256 i = 0; i < _froms.length; i++) {
            _claimYield(_froms[i], _tos[i]);
        }
    }

    // TODO: should this be restricted to only the recipient/streamer?
    function _claimYield(address _from, address _to) internal {
        // require(_from == msg.sender || _to == msg.sender, "ERC4626StreamHub: caller is not a party to the stream");

        YieldStream storage stream = yieldStreams[getStreamId(_from, _to)];

        uint256 yield = _calculateYield(stream.shares, stream.principal);

        if (yield == 0) revert NoYieldToClaim();

        stream.shares -= _withdrawFromVault(yield, _to);

        emit ClaimYield(_from, _to, yield);
    }

    /**
     * @dev Closes a yield stream for a specific recipient.
     * If there is any yield to claim, it will be claimed and transferred to the recipient.
     * @param _to The address of the recipient.
     */
    function closeYieldStream(address _to) external {
        _closeYieldStream(_to);
    }

    /**
     * @dev Closes multiple yield streams for multiple recipients.
     * If there is any yield to claim on any stream, it will be claimed and transferred to the recipient.
     * @param _tos The array of recipient addresses.
     */
    function closeYieldStreamBatch(address[] calldata _tos) external {
        for (uint256 i = 0; i < _tos.length; i++) {
            _closeYieldStream(_tos[i]);
        }
    }

    function _closeYieldStream(address _to) internal {
        uint256 streamId = getStreamId(msg.sender, _to);
        YieldStream memory stream = yieldStreams[streamId];

        if (stream.shares == 0) revert StreamDoesNotExist();

        uint256 yield = _calculateYield(stream.shares, stream.principal);

        // claim yield if any
        if (yield != 0) stream.shares -= _withdrawFromVault(yield, _to);

        balanceOf[msg.sender] += stream.shares;

        emit CloseYieldStream(msg.sender, _to, stream.shares);

        delete yieldStreams[streamId];
    }

    /**
     * @dev Calculates the yield for a given stream between two addresses.
     * @param _from The address of the sender.
     * @param _to The address of the recipient.
     * @return The calculated yield.
     */
    function yieldFor(address _from, address _to) external view returns (uint256) {
        YieldStream memory stream = yieldStreams[getStreamId(_from, _to)];

        return _calculateYield(stream.shares, stream.principal);
    }

    /**
     * @dev Generates a unique stream ID based on the sender and recipient addresses.
     * @param _from The address of the sender.
     * @param _to The address of the recipient.
     * @return The generated stream ID.
     */
    function getStreamId(address _from, address _to) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_from, _to)));
    }

    function _calculateYield(uint256 _shares, uint256 _valueAtOpen) internal view returns (uint256) {
        uint256 currentValue = _convertToAssets(_shares);

        return currentValue > _valueAtOpen ? currentValue - _valueAtOpen : 0;
    }

    function _checkReceiverAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
    }

    function _checkSufficientShares(uint256 _shares) internal view {
        if (_shares == 0) revert ZeroShares();

        if (_shares > balanceOf[msg.sender]) revert NotEnoughShares();
    }

    function _withdrawFromVault(uint256 _assets, address _receiver) internal returns (uint256) {
        return vault.withdraw(_assets, _receiver, address(this));
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return vault.convertToAssets(_shares);
    }
}
