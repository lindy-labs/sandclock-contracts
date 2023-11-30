// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

// TODO: add events
contract ERC4626StreamHub is Multicall {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    error NotEnoughShares();
    error ZeroSharesStreamNotAllowed();
    error InvalidReceiverAddress();
    error StreamDoesntExist();
    error NoYieldToClaim();
    error InputParamsLengthMismatch();

    IERC4626 public vault;

    mapping(address => uint256) public balanceOf;
    mapping(uint256 => YieldStream) public yieldStreams;
    // TODO: required for frontend?
    mapping(address => address[]) public receiverToDepositors;
    mapping(address => address[]) public depositorToReceivers;

    struct YieldStream {
        uint256 shares;
        uint256 principal;
        address recipient;
    }

    constructor(IERC4626 _vault) {
        vault = _vault;
        IERC20(vault.asset()).approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 _shares) external {
        vault.safeTransferFrom(msg.sender, address(this), _shares);
        balanceOf[msg.sender] += _shares;
    }

    function depositAssets(uint256 _assets) external returns (uint256) {
        IERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), _assets);

        uint256 shares = vault.deposit(_assets, address(this));
        balanceOf[msg.sender] += shares;

        return shares;
    }

    function withdraw(uint256 _shares) external {
        _checkSufficientShares(_shares);

        balanceOf[msg.sender] -= _shares;
        vault.transfer(msg.sender, _shares);
    }

    function withdrawAssets(uint256 _assets) external returns (uint256) {
        uint256 shares = vault.convertToShares(_assets);
        _checkSufficientShares(shares);

        balanceOf[msg.sender] -= shares;
        vault.redeem(shares, msg.sender, address(this));

        return shares;
    }

    function openYieldStream(uint256 _shares, address _to) external {
        _openYieldStream(_shares, _to);
    }

    function openYieldStreamMultiple(address[] calldata _receivers, uint256[] calldata _allocations) external {
        if (_receivers.length != _allocations.length) revert InputParamsLengthMismatch();

        for (uint256 i = 0; i < _receivers.length; i++) {
            _openYieldStream(_allocations[i], _receivers[i]);
        }
    }

    function claimYield(address _from, address _to) public {
        _claimYield(_from, _to);
    }

    function claimYieldMultiple(address[] calldata _froms, address[] calldata _tos) external {
        if (_froms.length != _tos.length) revert InputParamsLengthMismatch();

        for (uint256 i = 0; i < _froms.length; i++) {
            claimYield(_froms[i], _tos[i]);
        }
    }

    // TODO: should this be restricted to only the recipient/streamer?
    function _claimYield(address _from, address _to) internal {
        // require(_from == msg.sender || _to == msg.sender, "ERC4626StreamHub: caller is not a party to the stream");

        uint256 streamId = getStreamId(_from, _to);
        YieldStream storage stream = yieldStreams[streamId];

        uint256 yield = _calculateYield(stream.shares, stream.principal);

        if (yield == 0) revert NoYieldToClaim();

        uint256 shares = vault.withdraw(yield, _to, address(this));

        stream.shares -= shares;
    }

    function closeYieldStream(address _to) external {
        uint256 streamId = getStreamId(msg.sender, _to);
        YieldStream memory stream = yieldStreams[streamId];

        if (stream.shares == 0) revert StreamDoesntExist();

        uint256 yield = _calculateYield(stream.shares, stream.principal);

        if (yield > 0) stream.shares -= vault.withdraw(yield, _to, address(this));

        balanceOf[msg.sender] += stream.shares;

        delete yieldStreams[streamId];
    }

    function yieldFor(address _from, address _to) external view returns (uint256) {
        uint256 streamId = getStreamId(_from, _to);
        YieldStream memory stream = yieldStreams[streamId];

        return _calculateYield(stream.shares, stream.principal);
    }

    function getStreamId(address _from, address _to) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_from, _to)));
    }

    function _openYieldStream(uint256 _shares, address _to) internal {
        _checkSufficientShares(_shares);
        _checkReceiverAddress(_to);

        balanceOf[msg.sender] -= _shares;
        uint256 streamId = getStreamId(msg.sender, _to);
        uint256 value = vault.convertToAssets(_shares);

        YieldStream storage stream = yieldStreams[streamId];
        stream.shares += _shares;
        stream.principal += value;
        stream.recipient = _to;
    }

    function _calculateYield(uint256 _shares, uint256 _valueAtOpen) internal view returns (uint256) {
        uint256 currentValue = vault.convertToAssets(_shares);

        return currentValue > _valueAtOpen ? currentValue - _valueAtOpen : 0;
    }

    function _checkReceiverAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
    }

    function _checkSufficientShares(uint256 _shares) internal view {
        if (_shares == 0) revert ZeroSharesStreamNotAllowed();

        if (_shares > balanceOf[msg.sender]) revert NotEnoughShares();
    }
}
