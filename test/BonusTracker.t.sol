// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MintableERC20} from "../src/staking/utils/MintableERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {BonusTracker} from "../src/staking/BonusTracker.sol";

contract BonusTrackerTest is DSTestPlus {
    using FixedPointMathLib for uint256;

    MockERC20 stakeToken;
    MintableERC20 rewardToken;
    uint256 internal constant PRECISION = 1e30;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    address constant tester = address(0x69);
    BonusTracker stakingPool;

    function setUp() public {
        stakeToken = new MockERC20("Mock Quartz", "QUARTZ", 18);
        rewardToken = new MintableERC20("Mock Multiplier Points", "bnQuartz", 18);
        stakingPool = new BonusTracker(address(stakeToken), "Staked Quartz", "sQuartz", address(rewardToken));

        rewardToken.initialize(address(stakingPool));
        stakeToken.mint(address(this), 1000 ether);
        stakeToken.approve(address(stakingPool), type(uint256).max);

        // do initial stake
        stakingPool.deposit(1 ether, address(this));
    }

    function testGas_deposit() public {
        hevm.warp(7 days);
        stakingPool.deposit(1 ether, address(this));
    }

    function testGas_withdraw() public {
        hevm.warp(7 days);
        stakingPool.withdraw(0.5 ether, address(this), address(this));
    }

    function testGas_claimRewards() public {
        hevm.warp(7 days);
        stakingPool.claimRewards(address(this));
    }

    function testCorrectness_stake(uint128 amount_, uint56 warpTime) public {
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

    function testCorrectness_claimReward(uint128 amount0_, uint128 amount1_, uint256 stakeTime) public {
        hevm.assume(amount0_ > 0);
        hevm.assume(amount1_ > 0);
        hevm.assume(stakeTime < 36500 days);
        hevm.assume(stakeTime > 0);
        uint256 amount0 = amount0_;
        uint256 amount1 = amount1_;

        /// -----------------------------------------------------------------------
        /// Stake using address(this)
        /// -----------------------------------------------------------------------

        // start from a clean slate
        stakingPool.claimRewards(address(this));
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
        hevm.warp(stakeTime + 1);

        // get reward
        uint256 beforeBalance = rewardToken.balanceOf(tester);
        stakingPool.claimRewards(tester);
        uint256 rewardAmount = rewardToken.balanceOf(tester) - beforeBalance;

        // check assertions
        uint256 expectedRewardAmount = amount1.mulDivDown(stakeTime.mulDivDown(PRECISION, 365 days), PRECISION);
        assertEq(rewardAmount, expectedRewardAmount);
    }

    function testFail_cannotReinitialize() public {
        rewardToken.initialize(address(this));
    }
}
