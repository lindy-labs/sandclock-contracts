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
    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares);
    event ClaimYield(address indexed streamer, address indexed receiver, uint256 yield);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares);

    ERC4626StreamHub public streamHub;
    IERC4626 public vault;
    IERC20Metadata public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new ERC20Mock("ERC20Mock", "ERC20Mock", address(this), 0);
        vault = new ERC4626Mock(asset, "ERC4626Mock", "ERC4626Mock");
        streamHub = new ERC4626StreamHub(vault);

        // make initial deposit to vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    // *** #deposit ***

    function test_deposit_tracksDepositedShares() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.deposit(shares);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), shares, "alice's balance");
        assertEq(vault.balanceOf(address(streamHub)), shares, "streamHub vault shares");
        assertEq(vault.balanceOf(alice), 0, "alice's vault shares");
        assertEq(asset.balanceOf(address(alice)), 0, "alice's assets");
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

        assertEq(streamHub.balanceOf(alice), shares, "alice's balance");
        assertEq(vault.balanceOf(address(streamHub)), shares, "streamHub vault shares");
        assertEq(vault.balanceOf(alice), 0, "alice's vault shares");
        assertEq(asset.balanceOf(address(alice)), 0, "alice's assets");
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

    // *** #depositAssets ***

    function test_depositAssets_tracksDepositedShares() public {
        uint256 amount = 1e18;
        deal(address(asset), alice, amount);
        uint256 expectedShares = vault.convertToShares(amount);

        vm.startPrank(alice);
        asset.approve(address(streamHub), amount);
        streamHub.depositAssets(amount);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), expectedShares, "alice's shares");
        assertEq(vault.balanceOf(address(streamHub)), expectedShares, "streamHub vault shares");
        assertEq(vault.balanceOf(alice), 0, "alice's vault shares");
        assertEq(asset.balanceOf(address(alice)), 0, "alice's assets");
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
        assertEq(vault.balanceOf(address(streamHub)), expectedShares, "streamHub vault shares");
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

    // *** #withdraw ***

    function test_withdraw_reduceWithdrawnShares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);
        uint256 withdrawShares = shares / 3;

        vm.startPrank(alice);
        streamHub.withdraw(withdrawShares);

        assertEq(streamHub.balanceOf(alice), shares - withdrawShares, "alice's shares");
        assertEq(vault.balanceOf(address(streamHub)), shares - withdrawShares, "streamHub vault shares");
        assertEq(vault.balanceOf(alice), withdrawShares, "alice's vault shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
    }

    function test_withdraw_cannotWithdrawSharesAllocatedToStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);
        uint256 sharesToAllocate = shares / 2;

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        uint256 withdrawShares = shares - sharesToAllocate + 1; // 1 more than available
        streamHub.withdraw(withdrawShares);
    }

    function test_withdraw_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);
        uint256 sharesToWithdraw = shares / 2;

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alice, sharesToWithdraw);

        vm.startPrank(alice);
        streamHub.withdraw(sharesToWithdraw);
    }

    // *** #withdrawAssets ***

    function test_withdrawAssets_reduceWithdrawnShares() public {
        uint256 deposit = 1e18;
        uint256 shares = _depositToVault(alice, deposit);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.withdrawAssets(deposit / 2);

        assertEq(streamHub.balanceOf(alice), shares / 2, "alice's shares");
        assertEq(vault.balanceOf(address(streamHub)), shares / 2, "streamHub vault shares");
        assertEq(vault.balanceOf(alice), 0, "alice's vault shares");
        assertEq(asset.balanceOf(alice), deposit / 2, "alice's assets");
    }

    function test_withdrawAssets_cannotWithdrawSharesAllocatedToStream() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        uint256 freeShares = streamHub.balanceOf(alice);

        uint256 withdrawAmount = vault.convertToAssets(freeShares + 1);

        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.withdrawAssets(withdrawAmount);
    }

    function test_withdrawAssets_emitsEvent() public {
        uint256 amount = 1e18;
        _depositToStreamHub(alice, _depositToVault(alice, amount));
        uint256 withdrawAmount = amount / 2;
        uint256 shares = vault.convertToShares(withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alice, shares);

        vm.startPrank(alice);
        streamHub.withdrawAssets(withdrawAmount);
    }

    // *** #openYieldStream ***

    function test_openYieldStream_toSelf() public {
        uint256 amount = 10e18;
        uint256 shares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(alice, shares);

        assertEq(streamHub.balanceOf(alice), 0);

        (uint256 streamShares, uint256 value) = streamHub.yieldStreams(streamHub.getStreamId(alice, alice));

        assertEq(streamShares, shares, "stream shares");
        assertEq(value, amount, "value at open");
    }

    function test_openYieldStream_failsIfNotEnoughShares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.openYieldStream(alice, shares + 1);
    }

    function test_openYieldStream_failsFor0Shares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.ZeroShares.selector);
        streamHub.openYieldStream(alice, 0);
    }

    function test_openYieldStream_failsIfReceiverIsAddress0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.InvalidReceiverAddress.selector);
        streamHub.openYieldStream(address(0), shares);
    }

    function test_openYieldStream_toAnother() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        assertEq(streamHub.balanceOf(alice), 0, "alice's shares");

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(streamShares, shares, "stream shares");
    }

    function test_openYieldStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 4e18);
        _depositToStreamHub(alice, shares);

        vm.expectEmit(true, true, true, true);
        emit OpenYieldStream(alice, bob, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);
    }

    function test_openYieldStream_toTwoAccountsAtTheSameTime() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);
        streamHub.openYieldStream(carol, shares / 4);

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, shares / 2, "bob's stream shares");

        (streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, shares / 4, "carol's stream shares");

        assertEq(streamHub.balanceOf(alice), shares / 4, "alice's shares");
    }

    function test_openYieldStream_topsUpExistingStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(streamShares, shares / 2, "stream shares before top up");
        assertEq(streamHub.balanceOf(alice), shares / 2, "alice's shares before top up");
        assertEq(asset.balanceOf(bob), 0, "bob's assets before top up");

        // top up stream
        streamHub.openYieldStream(bob, shares / 2);

        (streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(streamShares, shares, "stream shares after top up");
        assertEq(streamHub.balanceOf(alice), 0, "alice's shares after top up");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after top up");
    }

    function test_openYieldStream_topUpDoesntChangeYieldAccrued() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        _createProfitForVault(0.2e18);
        uint256 yield = streamHub.yieldFor(alice, bob);

        assertEq(streamHub.yieldFor(alice, bob), yield, "yield before top up");

        // top up stream
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(streamHub.yieldFor(alice, bob), yield, "yield after top up");
    }

    function test_openYieldStream_topUpAffectsFutureYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        // double the share price
        _createProfitForVault(1e18);

        // top up stream with the remaining shares
        streamHub.openYieldStream(bob, shares / 2);

        _createProfitForVault(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        assertEq(streamHub.yieldFor(alice, bob), (amount * 2).mulWadUp(0.75e18), "yield");
    }

    // *** #openYieldStreamBatch ***

    function test_openYieldStreamBatch_createsStreamsForAllReceivers() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = shares * 3 / 4;
        allocations[1] = shares / 4;

        vm.startPrank(alice);
        streamHub.openYieldStreamBatch(receivers, allocations);

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, shares * 3 / 4, "bob's stream shares");

        (streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, shares / 4, "carol's stream shares");
    }

    function test_openYieldStreamBatch_failsIfReceiversAndAllocationLengthsDontMatch() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = shares;

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.InputParamsLengthMismatch.selector);
        streamHub.openYieldStreamBatch(receivers, allocations);
    }

    function test_openYieldStreamBatch_failsIfAllocationIsGreaterThanSharesBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = shares;
        allocations[1] = 1;

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.NotEnoughShares.selector);
        streamHub.openYieldStreamBatch(receivers, allocations);
    }

    // *** #yieldFor ***

    function test_yieldFor_returns0IfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // no share price increase => no yield
        assertEq(streamHub.yieldFor(alice, bob), 0, "yield");
    }

    function test_yieldFor_returns0IfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // no share price increase => no yield
        assertEq(streamHub.yieldFor(alice, bob), 0, "yield");
    }

    // *** #claimYield ***

    function test_claimYield_toSelf() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        streamHub.openYieldStream(alice, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.claimYield(alice, alice);

        assertEq(streamHub.balanceOf(alice), 0, "alice's shares");
        assertEq(asset.balanceOf(alice), amount / 2, "alice's assets");
    }

    function test_claimYield_toClaimerAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.claimYield(alice, bob);

        assertEq(streamHub.balanceOf(alice), 0, "alice's shares");
        assertEq(asset.balanceOf(bob), amount / 2, "bob's assets");
    }

    function test_claimYield_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 3e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = streamHub.yieldFor(alice, bob);

        vm.expectEmit(true, true, true, true);
        emit ClaimYield(alice, bob, yield);

        streamHub.claimYield(alice, bob);
    }

    function test_claimYield_revertsIfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        vm.expectRevert(ERC4626StreamHub.NoYieldToClaim.selector);
        streamHub.claimYield(alice, bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(ERC4626StreamHub.NoYieldToClaim.selector);
        streamHub.claimYield(alice, bob);
    }

    function test_claimYield_twoStreamsFromSameDepositorHaveSeparateYields() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);
        streamHub.openYieldStream(carol, shares / 2);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        streamHub.claimYield(alice, bob);

        assertEq(asset.balanceOf(bob), amount / 2, "bob's assets");
        assertEq(streamHub.yieldFor(alice, bob), 0, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(streamHub.yieldFor(alice, carol), amount / 2, "carol's yield");

        // add 100% profit to vault again
        _createProfitForVault(1e18);

        streamHub.claimYield(alice, carol);

        assertEq(asset.balanceOf(bob), amount / 2, "bob's assets");
        assertEq(streamHub.yieldFor(alice, bob), amount / 2, "bob's yield");
        // total value of shares increased by 300% from the initial deposit (4x)
        // since carol didn't claim yield early, her yield is 3 x the initial deposit of the stream
        assertEq(asset.balanceOf(carol), amount / 2 * 3, "carol's assets");
        assertEq(streamHub.yieldFor(alice, carol), 0, "carol's yield");
    }

    // *** #claimYieldBatch ***

    function test_claimYieldBatch_claimsFromAllProvidedStreams() public {
        uint256 amount = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, alicesShares);
        uint256 bobsShares = _depositToVault(bob, amount * 2);
        _depositToStreamHub(bob, bobsShares);

        vm.prank(alice);
        streamHub.openYieldStream(carol, alicesShares);
        vm.prank(bob);
        streamHub.openYieldStream(carol, bobsShares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = bob;
        address[] memory tos = new address[](2);
        tos[0] = carol;
        tos[1] = carol;

        assertEq(streamHub.yieldFor(alice, carol), amount, "alice's yield");
        assertEq(streamHub.yieldFor(bob, carol), amount * 2, "bob's yield");

        streamHub.claimYieldBatch(froms, tos);

        assertEq(asset.balanceOf(carol), amount * 3, "carol's assets");
        assertEq(streamHub.yieldFor(alice, carol), 0, "alice's yield");
        assertEq(streamHub.yieldFor(bob, carol), 0, "bob's yield");
    }

    // *** #closeYieldStream ***

    function test_closeYieldStream_deletesStreamFromStorage() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = streamHub.yieldFor(alice, bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        // claim yield
        streamHub.closeYieldStream(bob);

        assertApproxEqAbs(streamHub.balanceOf(alice), shares - yieldValueInShares, 1, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(alice), 0, 1, "alice's assets");
        assertEq(asset.balanceOf(bob), yield, "bob's assets");

        // assert stream is deleted
        (uint256 shares_, uint256 value) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));

        assertEq(shares_, 0, "shares");
        assertEq(value, 0, "value at open");
    }

    function test_closeYieldStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        uint256 yield = streamHub.yieldFor(alice, bob);
        uint256 unlockedShares = shares - vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit CloseYieldStream(alice, bob, unlockedShares);
        emit ClaimYield(alice, bob, yield);

        streamHub.closeYieldStream(bob);
    }

    function test_closeYieldStream_stopsGeneratingFurtherYieldForReceiver() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        // claim yield
        streamHub.closeYieldStream(bob);

        assertEq(streamHub.yieldFor(alice, bob), 0, "bob's yield");
        uint256 bobsAssets = asset.balanceOf(bob);

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        assertEq(streamHub.yieldFor(alice, bob), 0, "bob's yield");
        assertEq(asset.balanceOf(bob), bobsAssets, "bob's assets");
    }

    function test_closeYieldStream_worksIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // claim yield
        streamHub.closeYieldStream(bob);

        assertEq(streamHub.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
    }

    function test_closeYieldStream_failsIfStreamIsAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // works
        streamHub.closeYieldStream(bob);

        // fails
        vm.expectRevert(ERC4626StreamHub.StreamDoesNotExist.selector);
        streamHub.closeYieldStream(bob);
    }

    function test_closeYieldStream_doesntAffectOtherStreamsFromTheSameDepositor() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);
        streamHub.openYieldStream(carol, shares / 2);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        uint256 bobsYield = streamHub.yieldFor(alice, bob);
        uint256 carolsYield = streamHub.yieldFor(alice, carol);

        assertTrue(bobsYield > 0, "bob's yield = 0");
        assertTrue(carolsYield > 0, "carol's yield = 0");

        streamHub.closeYieldStream(bob);

        assertEq(asset.balanceOf(bob), bobsYield, "bob's assets");
        assertEq(streamHub.yieldFor(alice, bob), 0, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(streamHub.yieldFor(alice, carol), carolsYield, "carol's yield");
    }

    function test_closeYieldStreamBatch_closesAllStreams() public {
        uint256 amount = 3e18;
        uint256 shares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 3);
        streamHub.openYieldStream(carol, shares / 3);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        streamHub.closeYieldStreamBatch(receivers);

        assertEq(asset.balanceOf(bob), amount / 3, "bob's assets");
        assertEq(asset.balanceOf(carol), amount / 3, "carol's assets");

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, 0, "bob's stream shares");
        (streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, 0, "carol's stream shares");
    }

    // *** #multicall ***

    function test_multicall_depositAndOpenYieldStream() public {
        uint256 shares = _depositToVault(alice, 1e18);

        // deposit to streamHub & open stream in one transaction
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.deposit.selector, shares);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, alice, shares);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.multicall(data);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), 0, "alice's shares");

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, alice));

        assertEq(streamShares, shares, "stream shares");
    }

    function test_multicall_depositAndOpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.deposit.selector, shares);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, bob, shares * 3 / 4);
        data[2] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, carol, shares / 4);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.multicall(data);
        vm.stopPrank();

        assertEq(streamHub.balanceOf(alice), 0, "alice's shares");

        (uint256 streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, bob));
        assertEq(streamShares, shares * 3 / 4, "bob's stream shares");

        (streamShares,) = streamHub.yieldStreams(streamHub.getStreamId(alice, carol));
        assertEq(streamShares, shares / 4, "carol's stream shares");
    }

    function test_multicall_claimYieldFromMultipleStreams() public {
        uint256 amount = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount);
        _depositToStreamHub(alice, alicesShares);
        uint256 bobsShares = _depositToVault(bob, amount * 2);
        _depositToStreamHub(bob, bobsShares);

        vm.prank(alice);
        streamHub.openYieldStream(carol, alicesShares);
        vm.prank(bob);
        streamHub.openYieldStream(carol, bobsShares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.claimYield.selector, alice, carol);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.claimYield.selector, bob, carol);

        assertEq(streamHub.yieldFor(alice, carol), amount, "alice's yield");
        assertEq(streamHub.yieldFor(bob, carol), amount * 2, "bob's yield");

        streamHub.multicall(data);

        assertEq(asset.balanceOf(carol), amount * 3, "carol's assets");
        assertEq(streamHub.yieldFor(alice, carol), 0, "alice's yield");
        assertEq(streamHub.yieldFor(bob, carol), 0, "bob's yield");
    }

    // *** helpers ***

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        deal(address(asset), _from, _amount);
        asset.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _depositToStreamHub(address _from, uint256 _shares) internal {
        vm.startPrank(_from);

        vault.approve(address(streamHub), _shares);
        streamHub.deposit(_shares);

        vm.stopPrank();
    }

    function _createProfitForVault(int256 _profit) internal {
        deal(address(asset), address(vault), vault.totalAssets().mulWadDown(uint256(1e18 + _profit)));
    }
}
