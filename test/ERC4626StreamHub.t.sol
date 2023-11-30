// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/interfaces/IERC20Metadata.sol";
import {ERC4626Mock} from "openzeppelin-contracts/mocks/ERC4626Mock.sol";
import {ERC20Mock} from "openzeppelin-contracts/mocks/ERC20Mock.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract ERC4626StreamHubTests is Test {
    using FixedPointMathLib for uint256;

    event Deposit(address indexed depositor, uint256 shares);
    event Withdraw(address indexed depositor, uint256 shares);

    ERC4626StreamHub public streamHub;
    IERC4626 public vault;
    IERC20Metadata public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new ERC20Mock("MockERC20", "Mock20", address(this), 0);
        vault = new ERC4626Mock(asset, "Mock4626", "Mock");
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

        // first deposit
        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.deposit(shares / 2);

        assertEq(streamHub.balanceOf(alice), shares / 2);

        // second deposit
        streamHub.deposit(shares / 2);

        assertEq(streamHub.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(streamHub)), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_deposit_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 2e18);
        uint256 depositShares = shares / 2;

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alice, depositShares);

        streamHub.deposit(depositShares);
    }

    function test_depositAssets_tracksDepositedShares() public {
        uint256 amount = 1e18;
        deal(address(asset), alice, amount);
        uint256 expectedShares = vault.convertToShares(amount);

        vm.startPrank(alice);
        asset.approve(address(streamHub), amount);
        streamHub.depositAssets(amount);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), expectedShares);
        assertEq(vault.balanceOf(address(streamHub)), expectedShares);
        assertEq(asset.balanceOf(address(alice)), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_depositAssets_secondDepositAddsSharesToPrevious() public {
        uint256 firstDeposit = 1e18;
        uint256 secondDeposit = 2e18;
        deal(address(asset), alice, firstDeposit + secondDeposit);

        // first deposit
        uint256 expectedShares = vault.convertToShares(firstDeposit);

        vm.startPrank(alice);
        asset.approve(address(streamHub), firstDeposit);
        uint256 firstDepositShares = streamHub.depositAssets(firstDeposit);
        vm.stopPrank();

        assertEq(firstDepositShares, expectedShares, "first deposit shares");
        assertEq(streamHub.balanceOf(alice), expectedShares, "alice's shares");
        assertEq(vault.balanceOf(address(streamHub)), expectedShares, "streamHub's shares");
        assertEq(vault.balanceOf(alice), 0, "alice's vault shares");

        // second deposit
        expectedShares = vault.convertToShares(secondDeposit);

        vm.startPrank(alice);
        asset.approve(address(streamHub), secondDeposit);
        uint256 secondDepositShares = streamHub.depositAssets(secondDeposit);
        vm.stopPrank();

        assertEq(secondDepositShares, expectedShares, "second deposit shares");
        assertEq(
            streamHub.balanceOf(alice), firstDepositShares + secondDepositShares, "alice's shares after second deposit"
        );
        assertEq(
            vault.balanceOf(address(streamHub)),
            firstDepositShares + secondDepositShares,
            "streamHub shares after second deposit"
        );
        assertEq(asset.balanceOf(address(alice)), 0, "alice's assets after second deposit");
        assertEq(vault.balanceOf(alice), 0, "alice's vault shares after second deposit");
    }

    function test_depositAssets_emitsEvent() public {
        uint256 amount = 3e18;
        deal(address(asset), alice, amount);

        vm.startPrank(alice);
        asset.approve(address(streamHub), amount);
        uint256 shares = vault.convertToShares(amount);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alice, shares);

        streamHub.depositAssets(amount);
    }

    function test_withdraw_reduceWithdrawnShares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);
        uint256 withdrawShares = shares / 3;

        vm.startPrank(alice);
        streamHub.withdraw(withdrawShares);

        assertEq(streamHub.balanceOf(alice), shares - withdrawShares);
        assertEq(vault.balanceOf(address(streamHub)), shares - withdrawShares);
        assertEq(vault.balanceOf(alice), withdrawShares);
        assertEq(asset.balanceOf(alice), 0);
    }

    function test_withdraw_cannotWithdrawSharesAllocatedToStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);
        uint256 sharesToAllocate = shares / 2;

        vm.startPrank(alice);
        streamHub.openYieldStream(shares / 2, bob);

        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        uint256 withdrawShares = shares - sharesToAllocate + 1; // 1 more than available
        streamHub.withdraw(withdrawShares);
    }

    function test_withdraw_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);
        uint256 sharesToWithdraw = shares / 2;

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alice, sharesToWithdraw);

        vm.startPrank(alice);
        streamHub.withdraw(sharesToWithdraw);
    }

    function test_withdrawAssets_reduceWithdrawnShares() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        streamHub.withdrawAssets(deposit / 2);

        assertEq(streamHub.balanceOf(alice), shares / 2);
        assertEq(vault.balanceOf(address(streamHub)), shares / 2);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), deposit / 2);
    }

    function test_withdrawAssets_cannotWithdrawSharesAllocatedToStream() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _depositToStreamVault(alice, shares);
        uint256 allocateShares = shares / 2;

        vm.startPrank(alice);
        streamHub.openYieldStream(allocateShares, bob);

        uint256 withdrawAmount = vault.convertToAssets(shares - allocateShares + 1); // 1 more than available

        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.withdrawAssets(withdrawAmount);
    }

    function test_withdrawAssets_emitsEvent() public {
        uint256 amount = 1e18;
        _depositToStreamVault(alice, _depositToVault(alice, amount));
        uint256 withdrawAmount = amount / 2;
        uint256 shares = vault.convertToShares(withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alice, shares);

        vm.startPrank(alice);
        streamHub.withdrawAssets(withdrawAmount);
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

    function test_openYieldStream_failsFor0Shares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.ZeroSharesStreamNotAllowed.selector);
        streamHub.openYieldStream(0, alice);
    }

    function test_openYieldStream_failsIfReceiverIsAddress0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamVault(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.InvalidReceiverAddress.selector);
        streamHub.openYieldStream(shares, address(0));
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

    function test_openYieldStreamMultiple_createsStreamsForAllReceivers() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = shares * 3 / 4;
        allocations[1] = shares / 4;

        vm.startPrank(alice);
        streamHub.openYieldStreamMultiple(receivers, allocations);

        (uint256 streamShares,, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, shares * 3 / 4);
        assertEq(receiver, bob);

        (streamShares,, receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, shares / 4);
        assertEq(receiver, carol);
    }

    function test_openYieldStreamMultiple_failsIfReceiversAndAllocationLengthsDontMatch() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = shares;

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.InputParamsLengthMismatch.selector);
        streamHub.openYieldStreamMultiple(receivers, allocations);
    }

    function test_openYieldStreamMultiple_failsIfAllocationIsGreaterThanSharesBalance() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = shares;
        allocations[1] = 1;

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.openYieldStreamMultiple(receivers, allocations);
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

    function test_claimYieldMultiple_claimsFromAllProvidedStreams() public {
        uint256 deposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, alicesShares);
        uint256 bobsShares = _depositToVault(bob, deposit * 2);
        _depositToStreamVault(bob, bobsShares);

        vm.prank(alice);
        streamHub.openYieldStream(alicesShares, carol);
        vm.prank(bob);
        streamHub.openYieldStream(bobsShares, carol);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = bob;
        address[] memory tos = new address[](2);
        tos[0] = carol;
        tos[1] = carol;

        assertEq(streamHub.yieldFor(alice, carol), deposit);
        assertEq(streamHub.yieldFor(bob, carol), deposit * 2);

        streamHub.claimYieldMultiple(froms, tos);

        assertEq(asset.balanceOf(carol), deposit * 3);
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

    function test_multicall_depositAndOpenYieldStream() public {
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

    function test_multicall_openMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.deposit.selector, shares);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, shares * 3 / 4, bob);
        data[2] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, shares / 4, carol);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.multicall(data);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), 0);

        (uint256 streamShares,, address receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, shares * 3 / 4);
        assertEq(receiver, bob);

        (streamShares,, receiver) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, shares / 4);
        assertEq(receiver, carol);
    }

    function test_multicall_claimYieldFromMultipleStreams() public {
        uint256 deposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, deposit);
        _depositToStreamVault(alice, alicesShares);
        uint256 bobsShares = _depositToVault(bob, deposit * 2);
        _depositToStreamVault(bob, bobsShares);

        vm.prank(alice);
        streamHub.openYieldStream(alicesShares, carol);
        vm.prank(bob);
        streamHub.openYieldStream(bobsShares, carol);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.claimYield.selector, alice, carol);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.claimYield.selector, bob, carol);

        assertEq(streamHub.yieldFor(alice, carol), deposit);
        assertEq(streamHub.yieldFor(bob, carol), deposit * 2);

        streamHub.multicall(data);

        assertEq(asset.balanceOf(carol), deposit * 3);
        assertEq(streamHub.yieldFor(alice, carol), 0);
        assertEq(streamHub.yieldFor(bob, carol), 0);
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
