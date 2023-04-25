// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {MintableERC20} from "./utils/MintableERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";

contract BonusTracker is ERC4626, ReentrancyGuard, AccessControl {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event RewardPaid(address indexed user, uint256 reward);

    uint256 internal constant PRECISION = 1e30;

    /// @notice The last Unix timestamp (in seconds) when rewardPerTokenStored was updated
    uint64 public lastUpdateTime;

    /// @notice The last stored rewardPerToken value
    uint256 public rewardPerTokenStored;

    /// @notice The rewardPerToken value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice The earned() value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public rewards;

    /// @notice The token being rewarded to stakers
    MintableERC20 public immutable rewardToken;

    constructor(address _stakeToken, string memory _name, string memory _symbol, address _rewardToken)
        ERC4626(ERC20(_stakeToken), _name, _symbol)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        rewardToken = MintableERC20(_rewardToken);
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = totalSupply;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _updateReward();
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 assets, address receiver) public override returns (uint256 shares) {
        _updateReward();
        shares = super.deposit(assets, receiver);
    }

    function beforeWithdraw(uint256, uint256) internal override {
        _updateReward();
    }

    /// @notice Withdraws all earned rewards
    function claimRewards(address _receiver) external nonReentrant returns (uint256 reward) {
        _updateReward();
        reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.mint(_receiver, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice The latest time at which stakers are earning rewards.
    function lastTimeRewardApplicable() public view returns (uint64) {
        return uint64(block.timestamp);
    }

    /// @notice The amount of reward tokens each staked token has earned so far
    function rewardPerToken() external view returns (uint256) {
        return _rewardPerToken(totalSupply, lastTimeRewardApplicable());
    }

    /// @notice The amount of reward tokens an account has accrued so far. Does not
    /// include already withdrawn rewards.
    function earned(address account) external view returns (uint256) {
        return _earned(
            account, balanceOf[account], _rewardPerToken(totalSupply, lastTimeRewardApplicable()), rewards[account]
        );
    }

    function _earned(address account, uint256 accountBalance, uint256 rewardPerToken_, uint256 accountRewards)
        internal
        view
        returns (uint256)
    {
        return
            accountBalance.mulDivDown((rewardPerToken_) - userRewardPerTokenPaid[account], PRECISION) + accountRewards;
    }

    function _rewardPerToken(uint256 totalSupply_, uint256 lastTimeRewardApplicable_) internal view returns (uint256) {
        if (totalSupply_ == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (lastTimeRewardApplicable_ - lastUpdateTime).mulDivDown(PRECISION, 365 days);
    }

    function _updateReward() internal {
        // storage loads
        uint256 accountBalance = balanceOf[msg.sender];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply;
        uint256 rewardPerToken_ = _rewardPerToken(totalSupply_, lastTimeRewardApplicable_);

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        rewards[msg.sender] = _earned(msg.sender, accountBalance, rewardPerToken_, rewards[msg.sender]);
        userRewardPerTokenPaid[msg.sender] = rewardPerToken_;
    }
}
