// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

contract ERC4626StreamHub is Multicall {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;

    error NotEnoughShares();
    error StreamDoesntExist();
    error NoYieldToClaim();

    ERC4626 public vault;
    ERC20 public asset;

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

    constructor(ERC4626 _vault) {
        vault = _vault;
        asset = _vault.asset();
    }

    // TODO: add deposit & openYieldStream in the same function?
    function deposit(uint256 _shares) external {
        vault.safeTransferFrom(msg.sender, address(this), _shares);
        balanceOf[msg.sender] += _shares;
    }

    function withdraw(uint256 _shares) external {
        if (_shares > balanceOf[msg.sender]) {
            revert NotEnoughShares();
        }

        balanceOf[msg.sender] -= _shares;
        vault.safeTransfer(msg.sender, _shares);
    }

    // TODO: open multiple streams at once?
    function openYieldStream(uint256 _shares, address _to) external {
        uint256 value = _shares.mulDivDown(vault.totalAssets(), vault.totalSupply());

        if (_shares > balanceOf[msg.sender]) {
            revert NotEnoughShares();
        }

        balanceOf[msg.sender] -= _shares;
        uint256 streamId = getStreamId(msg.sender, _to);

        YieldStream storage stream = yieldStreams[streamId];
        stream.shares += _shares;
        stream.principal += value;
        stream.recipient = _to;
    }

    // TODO: claim from multiple streams at once?
    function claimYield(address _from, address _to) external {
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

        if (yield > 0) {
            stream.shares -= vault.withdraw(yield, _to, address(this));
        }

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

    function _calculateYield(uint256 _shares, uint256 _valueAtOpen) internal view returns (uint256) {
        uint256 currentValue = _shares.mulDivDown(vault.totalAssets(), vault.totalSupply());

        return currentValue > _valueAtOpen ? currentValue - _valueAtOpen : 0;
    }
}
