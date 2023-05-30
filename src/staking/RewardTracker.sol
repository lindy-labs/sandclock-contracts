// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {BonusTracker} from "./BonusTracker.sol";

contract RewardTracker is BonusTracker, AccessControl {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);
    event VaultAdded(address vault);

    error Error_AmountTooLarge();

    /// @notice The last Unix timestamp (in seconds) when rewardPerTokenStored was updated
    uint64 public lastUpdateTime;

    /// @notice The Unix timestamp (in seconds) at which the current reward period ends
    uint64 public periodFinish;

    /// @notice The per-second rate at which rewardPerToken increases
    uint256 public rewardRate;

    /// @notice The last stored rewardPerToken value
    uint256 public rewardPerTokenStored;

    /// @notice Role allowed to call notifyReward()
    bytes32 public constant DISTRIBUTOR = keccak256("DISTRIBUTOR");

    /// @notice The rewardPerToken value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice The earned() value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public rewards;

    /// @notice A whitelist of vaults staking contract is collecting fees from
    mapping(address => bool) public isVault;

    /// @notice The token being rewarded to stakers
    ERC20 public immutable rewardToken;

    /// @notice The length of each reward period, in seconds
    uint64 immutable DURATION;

    constructor(address _stakeToken, string memory _name, string memory _symbol, address _rewardToken, uint64 _DURATION)
        BonusTracker(ERC20(_stakeToken), _name, _symbol)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        rewardToken = ERC20(_rewardToken);
        DURATION = _DURATION;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = totalSupply;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _updateReward(receiver);
        _updateBonus(receiver);
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        _updateReward(receiver);
        _updateBonus(receiver);
        assets = super.mint(shares, receiver);
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        _updateReward(msg.sender);
        _updateBonus(msg.sender);
        _burnMultiplierPoints(assets, msg.sender);
    }

    /// @notice Withdraws all earned rewards
    function claimRewards(address _receiver) external nonReentrant returns (uint256 reward) {
        _updateReward(_receiver);
        reward = rewards[_receiver];
        if (reward > 0) {
            rewards[_receiver] = 0;
            rewardToken.safeTransfer(_receiver, reward);
            emit RewardPaid(_receiver, reward);
        }
    }

    /// @notice The latest time at which stakers are earning rewards.
    function lastTimeRewardApplicable() public view returns (uint64) {
        return block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
    }

    /// @notice The amount of reward tokens each staked token has earned so far
    function rewardPerToken() external view returns (uint256) {
        return _rewardPerToken(totalSupply + totalBonus, lastTimeRewardApplicable(), rewardRate);
    }

    /// @notice The amount of reward tokens an account has accrued so far. Does not
    /// include already withdrawn rewards.
    function earned(address account) external view returns (uint256) {
        return _earned(
            account,
            balanceOf[account] + multiplierPointsOf[account],
            _rewardPerToken(totalSupply + totalBonus, lastTimeRewardApplicable(), rewardRate),
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
        _notifyRewardAmount(reward);
    }

    function _notifyRewardAmount(uint256 reward) internal {
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
        uint256 totalSupply_ = totalSupply + totalBonus;

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

    /// @notice Lets a reward distributor fetch performance fees from
    /// a vault and start a new reward period.
    function fetchRewards(ERC4626 vault) external onlyRole(DISTRIBUTOR) {
        require(isVault[address(vault)], "vault not whitelisted");
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        uint256 afterBalance = rewardToken.balanceOf(address(this));
        _notifyRewardAmount(afterBalance - beforeBalance);
    }

    /// @notice Lets an admin add a vault for collecting fees from.
    function addVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(ERC4626(vault).asset() == rewardToken, "only WETH assets");
        isVault[vault] = true;
        emit VaultAdded(vault);
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

    function _updateReward(address account) internal override {
        // storage loads
        uint256 accountBalance = balanceOf[account] + multiplierPointsOf[account];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply + totalBonus;
        uint256 rewardPerToken_ = _rewardPerToken(totalSupply_, lastTimeRewardApplicable_, rewardRate);

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        rewards[account] = _earned(account, accountBalance, rewardPerToken_, rewards[account]);
        userRewardPerTokenPaid[account] = rewardPerToken_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _updateReward(msg.sender);
        _updateReward(to);
        _updateBonus(msg.sender);
        _updateBonus(to);
        _burnMultiplierPoints(amount, msg.sender);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _updateReward(from);
        _updateReward(to);
        _updateBonus(from);
        _updateBonus(to);
        _burnMultiplierPoints(amount, from);
        return super.transferFrom(from, to, amount);
    }

    // burn multiplier points
    function _burnMultiplierPoints(uint256 amount, address sender) internal {
        uint256 bonus_ = multiplierPointsOf[sender];

        // if the sender has bonus points
        if (bonus_ > 0) {
            uint256 balance = balanceOf[sender];

            // burn an equivalent percentage
            bonus_ = bonus_.mulDivDown(amount, balance);
            multiplierPointsOf[sender] -= bonus_;
            totalBonus -= bonus_;
            emit BonusBurned(sender, bonus_);
        }
    }
}
