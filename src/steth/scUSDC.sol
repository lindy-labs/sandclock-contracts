// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {sc4626} from "../sc4626.sol";

contract scUSDC is sc4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 public totalInvested;
    uint256 public totalProfit;

    constructor(ERC20 _usdc) sc4626(_usdc, "Sandclock USDC Vault", "scUSDC") {}

    // need to be able to receive eth rewards
    receive() external payable {}

    function totalAssets() public view override returns (uint256 assets) {
        assets = asset.balanceOf(address(this));
    }

    function afterDeposit(uint256, uint256) internal override {}
    function beforeWithdraw(uint256, uint256) internal override {}

    // @dev: access control not needed, this is only separate to save
    // gas for users depositing, ultimately controlled by float %
    function depositIntoStrategy() external {
        _depositIntoStrategy();
    }

    function _depositIntoStrategy() internal {}

    function harvest() external onlyRole(KEEPER_ROLE) {}
}
