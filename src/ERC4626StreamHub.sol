// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

import {Constants as C} from "./lib/Constants.sol";

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

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

contract ERC4626StreamHubTests is Test {
    using FixedPointMathLib for uint256;

    ERC4626StreamHub public streamHub;
    MockERC4626 public vault;
    MockERC20 public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("MockERC20", "Mock20", 18);
        vault = new MockERC4626(asset, "Mock4626", "Mock");
        streamHub = new ERC4626StreamHub(vault);

        // make initial deposit to vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    function test_deposit_tracksDepositedShares() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.deposit(shares);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(streamHub)), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_deposit_secondDepositAddsSharesToPrevious() public {
        uint256 shares = _depositToVault(alice, 2e18);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.deposit(shares / 2);

        assertEq(streamHub.balanceOf(alice), shares / 2);

        streamHub.deposit(shares / 2);

        assertEq(streamHub.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(streamHub)), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_withdraw_reduceWithdrawnShares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.withdraw(shares / 2);

        assertEq(streamHub.balanceOf(alice), shares / 2);
        assertEq(vault.balanceOf(address(streamHub)), shares / 2);
        assertEq(vault.balanceOf(alice), shares / 2);
    }

    function test_withdraw_cannotWithdrawSharesAllocatedToStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);

        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.withdraw(shares);
    }

    function test_openYieldStream_toSelf() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, alice);

        assertEq(streamHub.balanceOf(alice), 0);

        (uint256 streamShares,, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, alice));

        assertEq(streamShares, shares);
        assertEq(receiver, alice);
    }

    function test_openYieldStream_failsIfNotEnoughShares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.openYieldStream(shares + 1, alice);
    }

    function test_openYieldStream_toAnother() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        assertEq(streamHub.balanceOf(alice), 0);

        (uint256 streamShares,, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(streamShares, shares);
        assertEq(receiver, bob);
    }

    function test_openYieldStream_toTwoAccountsAtTheSameTime() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);
        streamHub.openYieldStream(shares / 4, carol);

        (uint256 streamShares,, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, shares / 2);
        assertEq(receiver, bob);

        (streamShares,, receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, shares / 4);
        assertEq(receiver, carol);

        assertEq(streamHub.balanceOf(alice), shares / 4);
    }

    function test_openYieldStream_topsUpExistingStream() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);

        (uint256 streamShares,,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(streamShares, shares / 2);
        assertEq(streamHub.balanceOf(alice), shares / 2);
        assertEq(asset.balanceOf(bob), 0);

        // top up stream
        streamHub.openYieldStream(shares / 2, bob);

        (streamShares,,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(streamShares, shares);
        assertEq(streamHub.balanceOf(alice), 0);
        assertEq(asset.balanceOf(bob), 0);
    }

    function test_openYieldStream_topUpDoesntChangeYieldAccrued() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);

        _createProfitForVault(0.2e18);
        uint256 yield = streamHub.yieldFor(alice, bob);

        // top up stream
        streamHub.openYieldStream(shares / 2, bob);

        assertEq(streamHub.yieldFor(alice, bob), yield);
    }

    function test_openYieldStream_topUpAffectsFutureYield() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);

        // double the share price
        _createProfitForVault(1e18);

        // top up stream with the remaining shares
        streamHub.openYieldStream(shares / 2, bob);

        _createProfitForVault(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        assertEq(streamHub.yieldFor(alice, bob), (deposit * 2).mulWadUp(0.75e18));
    }

    function test_yieldFor_returns0IfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // no share price increase => no yield
        assertEq(streamHub.yieldFor(alice, bob), 0);
    }

    function test_yieldFor_returns0IfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // no share price increase => no yield
        assertEq(streamHub.yieldFor(alice, bob), 0);
    }

    function test_claimYield_toSelf() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        streamHub.openYieldStream(shares, alice);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.claimYield(alice, alice);

        assertEq(streamHub.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), deposit / 2);
    }

    function test_claimYield_toClaimerAccount() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.claimYield(alice, bob);

        assertEq(streamHub.balanceOf(alice), 0);
        assertEq(asset.balanceOf(bob), deposit / 2);
    }

    function test_claimYield_revertsIfNoYield() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        vm.expectRevert(ERC4626StreamHub.NoYieldToClaim.selector);
        streamHub.claimYield(alice, bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(ERC4626StreamHub.NoYieldToClaim.selector);
        streamHub.claimYield(alice, bob);
    }

    function test_claimYield_twoStreamsFromSameDepositorHaveSeparateYields() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);
        streamHub.openYieldStream(shares / 2, carol);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        streamHub.claimYield(alice, bob);

        assertEq(asset.balanceOf(bob), deposit / 2);
        assertEq(streamHub.yieldFor(alice, bob), 0);
        assertEq(asset.balanceOf(carol), 0);
        assertEq(streamHub.yieldFor(alice, carol), deposit / 2);

        // add 100% profit to vault again
        _createProfitForVault(1e18);

        streamHub.claimYield(alice, carol);

        assertEq(asset.balanceOf(bob), deposit / 2, "bob's assets");
        assertEq(streamHub.yieldFor(alice, bob), deposit / 2, "bob's yield");
        // total value of shares increased by 300% from the initial deposit (4x)
        // since carol didn't claim yield early, her yield is 3 x the initial deposit of the stream
        assertEq(asset.balanceOf(carol), deposit / 2 * 3, "carol's assets");
        assertEq(streamHub.yieldFor(alice, carol), 0, "carol's yield");
    }

    function test_closeYieldStream_deletesStreamFromStorage() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.closeYieldStream(bob);

        assertEq(asset.balanceOf(bob), deposit / 2);
        assertApproxEqAbs(asset.balanceOf(alice), 1, deposit);

        // assert stream is deleted
        (uint256 shares_, uint256 value, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(shares_, 0, "shares");
        assertEq(value, 0, "value at open");
        assertEq(receiver, address(0), "receiver");
    }

    function test_closeYieldStream_stopsGeneratingYieldForReceiver() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.closeYieldStream(bob);

        uint256 bobsAssets = asset.balanceOf(bob);

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        assertEq(streamHub.yieldFor(alice, bob), 0);
        assertEq(asset.balanceOf(bob), bobsAssets);
    }

    function test_closeYieldStream_unlocksSharesAndClaimsYield() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = streamHub.yieldFor(alice, bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        // claim yield
        streamHub.closeYieldStream(bob);

        assertApproxEqAbs(streamHub.balanceOf(alice), shares - yieldValueInShares, 1);
        assertEq(asset.balanceOf(bob), yield);
    }

    function test_closeYieldStream_worksWithWhenVaultMadeLosses() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // claim yield
        streamHub.closeYieldStream(bob);

        assertEq(streamHub.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
    }

    function test_closeYieldStream_failsIfStreamIsAlreadyClosed() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares, bob);

        // works
        streamHub.closeYieldStream(bob);

        // fails
        vm.expectRevert(ERC4626StreamHub.StreamDoesntExist.selector);
        streamHub.closeYieldStream(bob);
    }

    function test_closeYieldStream_doesntAffectOtherStreamsFromTheSameDepositor() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);
        streamHub.openYieldStream(shares / 2, carol);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        uint256 bobsYield = streamHub.yieldFor(alice, bob);
        uint256 carolsYield = streamHub.yieldFor(alice, carol);

        assertTrue(bobsYield > 0);
        assertTrue(carolsYield > 0);

        streamHub.closeYieldStream(bob);

        assertEq(asset.balanceOf(bob), bobsYield);
        assertEq(streamHub.yieldFor(alice, bob), 0);
        assertEq(asset.balanceOf(carol), 0);
        assertEq(streamHub.yieldFor(alice, carol), carolsYield);
    }

    function test_multicall_depositAndOpenYieldStreamInOneTransaction() public {
        uint256 shares = _depositToVault(alice, 1e18);

        // deposit to streamHub & open stream in one transaction
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.deposit.selector, shares);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, shares, alice);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.multicall(data);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), 0);

        (uint256 streamShares,, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, alice));

        assertEq(streamShares, shares);
        assertEq(receiver, alice);
    }

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        deal(address(asset), _from, _amount);
        asset.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _depositToStreamVault(address _from, uint256 _shares) internal {
        vm.startPrank(_from);

        vault.approve(address(streamHub), _shares);
        streamHub.deposit(_shares);

        vm.stopPrank();
    }

    function _createProfitForVault(int256 _profit) internal {
        deal(address(asset), address(vault), vault.totalAssets().mulWadDown(uint256(1e18 + _profit)));
    }
}
