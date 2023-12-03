// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

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

    function deposit(uint256 _shares) external {
        balanceOf[msg.sender] += _shares;
        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit Deposit(msg.sender, _shares);
    }

    function depositAssets(uint256 _assets) external returns (uint256 shares) {
        IERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), _assets);

        shares = vault.deposit(_assets, address(this));
        balanceOf[msg.sender] += shares;

        emit Deposit(msg.sender, shares);
    }

    function withdraw(uint256 _shares) external {
        _checkSufficientShares(_shares);

        balanceOf[msg.sender] -= _shares;
        vault.safeTransfer(msg.sender, _shares);

        emit Withdraw(msg.sender, _shares);
    }

    function withdrawAssets(uint256 _assets) external returns (uint256 shares) {
        shares = _withdrawFromVault(_assets, msg.sender);

        _checkSufficientShares(shares);
        balanceOf[msg.sender] -= shares;

        emit Withdraw(msg.sender, shares);
    }

    function openYieldStream(address _to, uint256 _shares) external {
        _openYieldStream(_to, _shares);
    }

    // TODO: do we need batch functions? same could be achieved using multicall
    function openYieldStreamBatch(address[] calldata _receivers, uint256[] calldata _shares) external {
        if (_receivers.length != _shares.length) revert InputParamsLengthMismatch();

        for (uint256 i = 0; i < _receivers.length; i++) {
            _openYieldStream(_receivers[i], _shares[i]);
        }
    }

    function _openYieldStream(address _to, uint256 _shares) internal {
        _checkSufficientShares(_shares);
        _checkReceiverAddress(_to);

        balanceOf[msg.sender] -= _shares;

        YieldStream storage stream = yieldStreams[getStreamId(msg.sender, _to)];
        stream.shares += _shares;
        stream.principal += _convertToAssets(_shares);

        emit OpenYieldStream(msg.sender, _to, _shares);
    }

    function claimYield(address _from, address _to) external {
        _claimYield(_from, _to);
    }

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

    function closeYieldStream(address _to) external {
        _closeYieldStream(_to);
    }

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

    function yieldFor(address _from, address _to) external view returns (uint256) {
        YieldStream memory stream = yieldStreams[getStreamId(_from, _to)];

        return _calculateYield(stream.shares, stream.principal);
    }

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
