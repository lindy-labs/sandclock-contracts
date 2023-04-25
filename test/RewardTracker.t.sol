// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {RewardTracker} from "../src/staking/RewardTracker.sol";
import {BonusTracker} from "../src/staking/BonusTracker.sol";

contract RewardTrackerTest is DSTestPlus {
    using FixedPointMathLib for uint256;

    MockERC20 stakeToken;
    MockERC20 rewardToken;
    MockERC20 bnQuartz;
    uint256 constant REWARD_AMOUNT = 10 ether;
    uint64 constant DURATION = 30 days;
    bytes32 public constant DISTRIBUTOR = keccak256("DISTRIBUTOR");
    address constant tester = address(0x69);
    BonusTracker sQuartz;
    RewardTracker stakingPool;

    function setUp() public {
        stakeToken = new MockERC20("Mock Quartz", "QUARTZ", 18);
        bnQuartz = new MockERC20("Mock Multiplier Points", "bnQuartz", 18);
        rewardToken = new MockERC20("Mock WETH", "WETH", 18);
        stakingPool =
        new RewardTracker(address(stakeToken), "Staked + Fee Quartz", "sfQuartz", address(rewardToken), address(bnQuartz), DURATION);
        sQuartz = new BonusTracker(address(stakingPool), "Staked Quartz", "sQuartz", address(bnQuartz));

        rewardToken.mint(address(this), 1000 ether);
        stakeToken.mint(address(this), 1000 ether);
        stakeToken.approve(address(stakingPool), type(uint256).max);
        stakingPool.approve(address(sQuartz), type(uint256).max);

        // do initial stake
        stakingPool.deposit(1 ether, address(this));
        sQuartz.deposit(1 ether, address(this));

        // distribute rewards
        rewardToken.transfer(address(stakingPool), REWARD_AMOUNT);
        stakingPool.grantRole(DISTRIBUTOR, address(this));
        stakingPool.notifyRewardAmount(REWARD_AMOUNT);
    }

    function testGas_deposit() public {
        hevm.warp(7 days);
        stakingPool.deposit(1 ether, address(this));
    }

    function testGas_withdraw() public {
        hevm.warp(7 days);
        sQuartz.withdraw(0.5 ether, address(this), address(this));
        stakingPool.withdraw(0.5 ether, address(this), address(this));
    }

    function testGas_claimRewards() public {
        hevm.warp(7 days);
        stakingPool.claimRewards(address(this));
    }

    function testCorrectness_deposit(uint128 amount_, uint56 warpTime) public {
        hevm.assume(amount_ > 0);
        hevm.assume(warpTime > 0);
        uint256 amount = amount_;

        hevm.startPrank(tester);

        // warp to future
        hevm.warp(warpTime);

        // mint stake tokens
        stakeToken.mint(tester, amount);

        // stake
        uint256 beforeStakingPoolStakeTokenBalance = stakeToken.balanceOf(address(stakingPool));
        stakeToken.approve(address(stakingPool), amount);
        stakingPool.deposit(amount, tester);

        // check balance
        assertEqDecimal(stakeToken.balanceOf(tester), 0, 18);
        assertEqDecimal(stakeToken.balanceOf(address(stakingPool)) - beforeStakingPoolStakeTokenBalance, amount, 18);
        assertEqDecimal(stakingPool.balanceOf(tester), amount, 18);
    }

    function testCorrectness_withdraw(uint128 amount_, uint56 warpTime, uint56 stakeTime) public {
        hevm.assume(amount_ > 0);
        hevm.assume(warpTime > 0);
        uint256 amount = amount_;
        amount = bound(amount, 1e5, 1e27);

        hevm.startPrank(tester);

        // warp to future
        hevm.warp(warpTime);

        // mint stake tokens
        stakeToken.mint(tester, amount);

        // stake
        uint256 beforeStakingPoolStakeTokenBalance = stakeToken.balanceOf(address(stakingPool));
        stakeToken.approve(address(stakingPool), amount);
        stakingPool.deposit(amount, tester);

        // warp to simulate staking
        hevm.warp(uint256(warpTime) + uint256(stakeTime));

        // withdraw
        stakingPool.withdraw(amount, tester, tester);

        // check balance
        assertEqDecimal(stakeToken.balanceOf(tester), amount, 18);
        assertEqDecimal(stakeToken.balanceOf(address(stakingPool)) - beforeStakingPoolStakeTokenBalance, 0, 18);
        assertEqDecimal(stakingPool.balanceOf(tester), 0, 18);
    }

    function testCorrectness_claimReward(uint128 amount0_, uint128 amount1_, uint8 stakeTimeAsDurationPercentage)
        public
    {
        hevm.assume(amount0_ > 0);
        hevm.assume(amount1_ > 0);
        hevm.assume(stakeTimeAsDurationPercentage > 0);
        uint256 amount0 = amount0_;
        uint256 amount1 = amount1_;

        /// -----------------------------------------------------------------------
        /// Stake using address(this)
        /// -----------------------------------------------------------------------

        // start from a clean slate
        stakingPool.claimRewards(address(this));
        sQuartz.withdraw(sQuartz.balanceOf(address(this)), address(this), address(this));
        stakingPool.withdraw(stakingPool.balanceOf(address(this)), address(this), address(this));

        // mint stake tokens
        stakeToken.mint(address(this), amount0);

        // stake
        stakingPool.deposit(amount0, address(this));

        /// -----------------------------------------------------------------------
        /// Stake using tester
        /// -----------------------------------------------------------------------

        hevm.startPrank(tester);

        // mint stake tokens
        stakeToken.mint(tester, amount1);

        // stake
        stakeToken.approve(address(stakingPool), amount1);
        stakingPool.deposit(amount1, tester);

        // warp to simulate staking
        uint256 stakeTime = (DURATION * uint256(stakeTimeAsDurationPercentage)) / 100;
        hevm.warp(stakeTime);

        // get reward
        uint256 beforeBalance = rewardToken.balanceOf(tester);
        emit log_uint(beforeBalance);
        stakingPool.claimRewards(tester);
        uint256 rewardAmount = rewardToken.balanceOf(tester) - beforeBalance;
        emit log_uint(rewardAmount);

        // check assertions
        uint256 expectedRewardAmount;
        if (stakeTime >= DURATION) {
            // past first reward period, all rewards have been distributed
            expectedRewardAmount = (REWARD_AMOUNT * amount1) / (amount0 + amount1);
        } else {
            // during first reward period, rewards are partially distributed
            expectedRewardAmount =
                (((REWARD_AMOUNT * stakeTimeAsDurationPercentage) / 100) * amount1) / (amount0 + amount1);
        }

        emit log_uint(REWARD_AMOUNT);
        emit log_uint(stakeTimeAsDurationPercentage);
        emit log_uint(stakeTime);
        emit log_uint(amount0);
        assertEqDecimalEpsilonBelow(rewardAmount, expectedRewardAmount, 18, 1e4);
    }

    function testCorrectness_notifyRewardAmount(uint128 amount_, uint56 warpTime, uint8 stakeTimeAsDurationPercentage)
        public
    {
        hevm.assume(amount_ > 0);
        hevm.assume(warpTime > 0);
        hevm.assume(stakeTimeAsDurationPercentage > 0);
        uint256 amount = amount_;

        // warp to some time in the future
        hevm.warp(warpTime);

        // get earned reward amount from existing rewards
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        stakingPool.claimRewards(address(this));
        uint256 rewardAmount = rewardToken.balanceOf(address(this)) - beforeBalance;

        // compute expected earned rewards
        uint256 expectedRewardAmount;
        if (warpTime >= DURATION) {
            // past first reward period, all rewards have been distributed
            expectedRewardAmount = REWARD_AMOUNT;
        } else {
            // during first reward period, rewards are partially distributed
            expectedRewardAmount = (REWARD_AMOUNT * warpTime) / DURATION;
        }
        uint256 leftoverRewardAmount = REWARD_AMOUNT - expectedRewardAmount;

        // mint reward tokens
        rewardToken.mint(address(stakingPool), amount);

        // notify new rewards
        stakingPool.notifyRewardAmount(amount);

        // warp to simulate staking
        uint256 stakeTime = (DURATION * uint256(stakeTimeAsDurationPercentage)) / 100;
        hevm.warp(warpTime + stakeTime);

        // get reward
        beforeBalance = rewardToken.balanceOf(address(this));
        stakingPool.claimRewards(address(this));
        rewardAmount += rewardToken.balanceOf(address(this)) - beforeBalance;

        // check assertions
        if (stakeTime >= DURATION) {
            // past second reward period, all rewards have been distributed
            expectedRewardAmount += leftoverRewardAmount + amount;
        } else {
            // during second reward period, rewards are partially distributed
            expectedRewardAmount += ((leftoverRewardAmount + amount) * stakeTimeAsDurationPercentage) / 100;
        }
        assertEqDecimalEpsilonBelow(rewardAmount, expectedRewardAmount, 18, 1e4);
    }

    function testCorrectness_claimRewardWithMultiplier(
        uint128 amount0_,
        uint128 amount1_,
        uint8 stakeTimeAsDurationPercentage
    ) public {
        hevm.assume(amount0_ > 0);
        hevm.assume(amount1_ > 0);
        hevm.assume(stakeTimeAsDurationPercentage > 0);
        uint256 amount0 = amount0_;
        uint256 amount1 = amount1_;

        /// -----------------------------------------------------------------------
        /// Stake using address(this)
        /// -----------------------------------------------------------------------

        // start from a clean slate
        stakingPool.claimRewards(address(this));
        sQuartz.withdraw(sQuartz.balanceOf(address(this)), address(this), address(this));
        stakingPool.withdraw(stakingPool.balanceOf(address(this)), address(this), address(this));

        // mint stake tokens
        stakeToken.mint(address(this), amount0);

        // stake
        uint256 sQuartz0 = stakingPool.deposit(amount0, address(this));

        // stake for multiplier points
        sQuartz.deposit(sQuartz0, address(this));

        /// -----------------------------------------------------------------------
        /// Stake using tester
        /// -----------------------------------------------------------------------

        hevm.startPrank(tester);

        // mint stake tokens
        stakeToken.mint(tester, amount1);

        // stake
        stakeToken.approve(address(stakingPool), amount1);
        uint256 sQuartz1 = stakingPool.deposit(amount1, tester);

        stakingPool.approve(address(sQuartz), sQuartz1);

        // stake for multiplier points
        sQuartz.deposit(sQuartz1, tester);

        // warp to simulate staking
        uint256 stakeTime = (DURATION * uint256(stakeTimeAsDurationPercentage)) / 100;
        hevm.warp(stakeTime);

        // compound multiplier points
        hevm.stopPrank();
        uint256 reward0 = sQuartz.claimRewards(address(this));
        bnQuartz.approve(address(stakingPool), reward0);
        emit log_uint(bnQuartz.balanceOf(address(this)));
        stakingPool.depositMultiplierPoints(reward0);

        // compound multiplier points
        hevm.startPrank(tester);
        uint256 reward1 = sQuartz.claimRewards(tester);
        bnQuartz.approve(address(stakingPool), reward1);
        stakingPool.depositMultiplierPoints(reward1);

        // get reward
        uint256 beforeBalance = rewardToken.balanceOf(tester);
        emit log_uint(bnQuartz.balanceOf(address(stakingPool)));
        emit log_uint(rewardToken.balanceOf(address(stakingPool)));
        emit log_uint(stakingPool.earned(tester));
        stakingPool.claimRewards(tester);
        uint256 rewardAmount = rewardToken.balanceOf(tester) - beforeBalance;

        // check assertions
        uint256 expectedRewardAmount;
        if (stakeTime >= DURATION) {
            // past first reward period, all rewards have been distributed
            expectedRewardAmount = (REWARD_AMOUNT * amount1) / (amount0 + amount1);
        } else {
            // during first reward period, rewards are partially distributed
            expectedRewardAmount =
                (((REWARD_AMOUNT * stakeTimeAsDurationPercentage) / 100) * amount1) / (amount0 + amount1);
        }

        emit log_uint(REWARD_AMOUNT);
        emit log_uint(stakeTimeAsDurationPercentage);
        emit log_uint(stakeTime);
        emit log_uint(amount0);

        assertEqDecimalEpsilonBelow(rewardAmount, expectedRewardAmount, 18, 1e4);
    }

    function assertEqDecimalEpsilonBelow(uint256 a, uint256 b, uint256 decimals, uint256 epsilonInv) internal {
        assertLeDecimal(a, b, decimals);
        assertGeDecimal(a, b - b / epsilonInv, decimals);
    }
}
