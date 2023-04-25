// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";

contract RewardTracker is ERC4626, AccessControl, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);
    event BonusDeposited(address indexed user, uint256 points);

    error Error_AmountTooLarge();

    uint256 internal constant PRECISION = 1e30;

    /// @notice The last Unix timestamp (in seconds) when rewardPerTokenStored was updated
    uint64 public lastUpdateTime;

    /// @notice The Unix timestamp (in seconds) at which the current reward period ends
    uint64 public periodFinish;

    /// @notice The per-second rate at which rewardPerToken increases
    uint256 public rewardRate;

    /// @notice The last stored rewardPerToken value
    uint256 public rewardPerTokenStored;

    /// @notice The number of multiplier points compounded for an account
    mapping(address => uint256) public multiplierPointsOf;

    /// @notice Role allowed to call notifyReward()
    bytes32 public constant DISTRIBUTOR = keccak256("DISTRIBUTOR");

    /// @notice The rewardPerToken value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice The earned() value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public rewards;

    /// @notice The token being rewarded to stakers
    ERC20 public immutable rewardToken;

    /// @notice The token representing multiplier points
    ERC20 public immutable bnQuartz;

    /// @notice The length of each reward period, in seconds
    uint64 immutable DURATION;

    constructor(
        address _stakeToken,
        string memory _name,
        string memory _symbol,
        address _rewardToken,
        address _bnQuartz,
        uint64 _DURATION
    ) ERC4626(ERC20(_stakeToken), _name, _symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        rewardToken = ERC20(_rewardToken);
        bnQuartz = ERC20(_bnQuartz);
        DURATION = _DURATION;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = totalSupply;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _updateReward();
        shares = super.deposit(assets, receiver);
    }

    function depositMultiplierPoints(uint256 points) public {
        _updateReward();
        bnQuartz.safeTransferFrom(msg.sender, address(this), points);
        multiplierPointsOf[msg.sender] += points;
        emit BonusDeposited(msg.sender, points);
    }

    function mint(uint256 assets, address receiver) public override returns (uint256 shares) {
        _updateReward();
        shares = super.deposit(assets, receiver);
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        _updateReward();

        // burn multiplier points
        if (balanceOf[msg.sender] - assets > 0) {
            uint256 burnAmount = multiplierPointsOf[msg.sender].mulDivDown(assets, balanceOf[msg.sender] - assets);
            bnQuartz.safeTransferFrom(address(this), address(0), burnAmount);
        }
    }

    /// @notice Withdraws all earned rewards
    function claimRewards(address _receiver) external nonReentrant returns (uint256 reward) {
        _updateReward();
        reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(_receiver, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice The latest time at which stakers are earning rewards.
    function lastTimeRewardApplicable() public view returns (uint64) {
        return block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
    }

    /// @notice The amount of reward tokens each staked token has earned so far
    function rewardPerToken() external view returns (uint256) {
        return _rewardPerToken(totalSupply + bnQuartz.balanceOf(address(this)), lastTimeRewardApplicable(), rewardRate);
    }

    /// @notice The amount of reward tokens an account has accrued so far. Does not
    /// include already withdrawn rewards.
    function earned(address account) external view returns (uint256) {
        return _earned(
            account,
            balanceOf[account] + multiplierPointsOf[account],
            _rewardPerToken(totalSupply + bnQuartz.balanceOf(address(this)), lastTimeRewardApplicable(), rewardRate),
            rewards[account]
        );
    }

    /// @notice Lets a reward distributor start a new reward period. The reward tokens must have already
    /// been transferred to this contract before calling this function. If it is called
    /// when a reward period is still active, a new reward period will begin from the time
    /// of calling this function, using the leftover rewards from the old reward period plus
    /// the newly sent rewards as the reward.
    /// @dev If the reward amount will cause an overflow when computing rewardPerToken, then
    /// this function will revert.
    /// @param reward The amount of reward tokens to use in the new reward period.
    function notifyRewardAmount(uint256 reward) external onlyRole(DISTRIBUTOR) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (reward == 0) {
            return;
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 rewardRate_ = rewardRate;
        uint64 periodFinish_ = periodFinish;
        uint64 lastTimeRewardApplicable_ = block.timestamp < periodFinish_ ? uint64(block.timestamp) : periodFinish_;
        uint64 DURATION_ = DURATION;
        uint256 totalSupply_ = totalSupply + bnQuartz.balanceOf(address(this));

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        rewardPerTokenStored = _rewardPerToken(totalSupply_, lastTimeRewardApplicable_, rewardRate_);
        lastUpdateTime = lastTimeRewardApplicable_;

        // record new reward
        uint256 newRewardRate;
        if (block.timestamp >= periodFinish_) {
            newRewardRate = reward / DURATION_;
        } else {
            uint256 remaining = periodFinish_ - block.timestamp;
            uint256 leftover = remaining * rewardRate_;
            newRewardRate = (reward + leftover) / DURATION_;
        }
        // prevent overflow when computing rewardPerToken
        if (newRewardRate >= ((type(uint256).max / PRECISION) / DURATION_)) {
            revert Error_AmountTooLarge();
        }
        rewardRate = newRewardRate;
        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp + DURATION_);

        emit RewardAdded(reward);
    }

    function _earned(address account, uint256 accountBalance, uint256 rewardPerToken_, uint256 accountRewards)
        internal
        view
        returns (uint256)
    {
        return accountBalance.mulDivDown(rewardPerToken_ - userRewardPerTokenPaid[account], PRECISION) + accountRewards;
    }

    function _rewardPerToken(uint256 totalSupply_, uint256 lastTimeRewardApplicable_, uint256 rewardRate_)
        internal
        view
        returns (uint256)
    {
        if (totalSupply_ == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + rewardRate_.mulDivDown((lastTimeRewardApplicable_ - lastUpdateTime) * PRECISION, totalSupply_);
    }

    function _updateReward() internal {
        // storage loads
        uint256 accountBalance = balanceOf[msg.sender] + multiplierPointsOf[msg.sender];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply + bnQuartz.balanceOf(address(this));
        uint256 rewardPerToken_ = _rewardPerToken(totalSupply_, lastTimeRewardApplicable_, rewardRate);

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        rewards[msg.sender] = _earned(msg.sender, accountBalance, rewardPerToken_, rewards[msg.sender]);
        userRewardPerTokenPaid[msg.sender] = rewardPerToken_;
    }
}
