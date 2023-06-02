// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {BonusTracker} from "./BonusTracker.sol";
import {CallerNotAdmin} from "../errors/scErrors.sol";

contract RewardTracker is BonusTracker, AccessControl {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);
    event VaultAdded(address vault);

    error Error_AmountTooLarge();
    error CallerNotDistirbutor();
    error VaultNotWhitelisted();
    error VaultAssetNotSupported();

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
    uint64 immutable duration;

    constructor(address _stakeToken, string memory _name, string memory _symbol, address _rewardToken, uint64 _duration)
        BonusTracker(ERC20(_stakeToken), _name, _symbol)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        rewardToken = ERC20(_rewardToken);
        duration = _duration;
    }

    modifier onlyDistributor() {
        if (!hasRole(DISTRIBUTOR, msg.sender)) revert CallerNotDistirbutor();
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert CallerNotAdmin();
        _;
    }

    function totalAssets() public view override returns (uint256) {
        return totalSupply;
    }

    function deposit(uint256 _assets, address _receiver) public override returns (uint256 shares) {
        _updateReward(_receiver);
        _updateBonus(_receiver);
        shares = super.deposit(_assets, _receiver);
    }

    function mint(uint256 _shares, address _receiver) public override returns (uint256 assets) {
        _updateReward(_receiver);
        _updateBonus(_receiver);
        assets = super.mint(_shares, _receiver);
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        _updateReward(msg.sender);
        _updateReward(_to);
        _updateBonus(msg.sender);
        _updateBonus(_to);
        _burnMultiplierPoints(_amount, msg.sender);

        return super.transfer(_to, _amount);
    }

    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        _updateReward(_from);
        _updateReward(_to);
        _updateBonus(_from);
        _updateBonus(_to);
        _burnMultiplierPoints(_amount, _from);

        return super.transferFrom(_from, _to, _amount);
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
        return _calcRewardPerToken(totalSupply + totalBonus, lastTimeRewardApplicable(), rewardRate);
    }

    /// @notice The amount of reward tokens an account has accrued so far. Does not
    /// include already withdrawn rewards.
    function earned(address _account) external view returns (uint256) {
        return _earned(
            _account,
            balanceOf[_account] + multiplierPointsOf[_account],
            _calcRewardPerToken(totalSupply + totalBonus, lastTimeRewardApplicable(), rewardRate),
            rewards[_account]
        );
    }

    /// @notice Lets a reward distributor start a new reward period. The reward tokens must have already
    /// been transferred to this contract before calling this function. If it is called
    /// when a reward period is still active, a new reward period will begin from the time
    /// of calling this function, using the leftover rewards from the old reward period plus
    /// the newly sent rewards as the reward.
    /// @dev If the reward amount will cause an overflow when computing rewardPerToken, then
    /// this function will revert.
    /// @param _reward The amount of reward tokens to use in the new reward period.
    function notifyRewardAmount(uint256 _reward) external onlyDistributor {
        _notifyRewardAmount(_reward);
    }

    /// @notice Lets a reward distributor fetch performance fees from
    /// a vault and start a new reward period.
    function fetchRewards(ERC4626 _vault) external onlyDistributor {
        if (!isVault[address(_vault)]) revert VaultNotWhitelisted();

        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        _vault.redeem(_vault.balanceOf(address(this)), address(this), address(this));

        uint256 afterBalance = rewardToken.balanceOf(address(this));
        _notifyRewardAmount(afterBalance - beforeBalance);
    }

    /// @notice Lets an admin add a vault for collecting fees from.
    function addVault(address _vault) external onlyAdmin {
        if (ERC4626(_vault).asset() != rewardToken) revert VaultAssetNotSupported();

        isVault[_vault] = true;

        emit VaultAdded(_vault);
    }

    function _notifyRewardAmount(uint256 _reward) internal {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (_reward == 0) {
            return;
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 rewardRate_ = rewardRate;
        uint64 periodFinish_ = periodFinish;
        uint64 lastTimeRewardApplicable_ = block.timestamp < periodFinish_ ? uint64(block.timestamp) : periodFinish_;
        uint64 duration_ = duration;
        uint256 totalSupply_ = totalSupply + totalBonus;

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        rewardPerTokenStored = _calcRewardPerToken(totalSupply_, lastTimeRewardApplicable_, rewardRate_);
        lastUpdateTime = lastTimeRewardApplicable_;

        // record new reward
        uint256 newRewardRate;

        if (block.timestamp >= periodFinish_) {
            newRewardRate = _reward / duration_;
        } else {
            uint256 remaining = periodFinish_ - block.timestamp;
            uint256 leftover = remaining * rewardRate_;
            newRewardRate = (_reward + leftover) / duration_;
        }

        // prevent overflow when computing rewardPerToken
        if (newRewardRate >= ((type(uint256).max / PRECISION) / duration_)) {
            revert Error_AmountTooLarge();
        }

        rewardRate = newRewardRate;
        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp + duration_);

        emit RewardAdded(_reward);
    }

    function beforeWithdraw(uint256 _assets, uint256) internal override {
        _updateReward(msg.sender);
        _updateBonus(msg.sender);
        _burnMultiplierPoints(_assets, msg.sender);
    }

    function _earned(address _account, uint256 _accountBalance, uint256 rewardPerToken_, uint256 _accountRewards)
        internal
        view
        returns (uint256)
    {
        return
            _accountBalance.mulDivDown(rewardPerToken_ - userRewardPerTokenPaid[_account], PRECISION) + _accountRewards;
    }

    function _calcRewardPerToken(uint256 _totalSupply, uint256 _lastTimeRewardApplicable, uint256 _rewardRate)
        internal
        view
        returns (uint256)
    {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored
            + _rewardRate.mulDivDown((_lastTimeRewardApplicable - lastUpdateTime) * PRECISION, _totalSupply);
    }

    function _updateReward(address _account) internal override {
        // storage loads
        uint256 accountBalance = balanceOf[_account] + multiplierPointsOf[_account];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply + totalBonus;
        uint256 rewardPerToken_ = _calcRewardPerToken(totalSupply_, lastTimeRewardApplicable_, rewardRate);

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        rewards[_account] = _earned(_account, accountBalance, rewardPerToken_, rewards[_account]);
        userRewardPerTokenPaid[_account] = rewardPerToken_;
    }

    // burn multiplier points
    function _burnMultiplierPoints(uint256 _amount, address _sender) internal {
        uint256 bonus_ = multiplierPointsOf[_sender];

        // return if no bonus points
        if (bonus_ == 0) return;

        // otherwise burn an equivalent percentage
        uint256 balance = balanceOf[_sender];
        bonus_ = bonus_.mulDivDown(_amount, balance);
        multiplierPointsOf[_sender] -= bonus_;
        totalBonus -= bonus_;
        emit BonusBurned(_sender, bonus_);
    }
}
