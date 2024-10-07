// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../lib/Constants.sol";
import {scSDAI} from "./scSDAI.sol";

/**
 * @title scDAI
 * @notice Sandclock DAI Vault - A wrapper ERC4626 contract to support DAI deposits and withdrawals on scSDAI.
 * @dev This contract allows users to deposit DAI and interact with the scSDAI vault seamlessly.
 */
contract scDAI is ERC4626 {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;

    /// @notice The DAI ERC20 token contract.
    ERC20 public constant dai = ERC20(C.DAI);

    /// @notice The sDAI ERC4626 token contract.
    ERC4626 public constant sDai = ERC4626(C.SDAI);

    /// @notice The scSDAI ERC4626 vault contract.
    ERC4626 public immutable scsDai;

    constructor(ERC4626 _scsDAI) ERC4626(dai, "Sandclock Yield DAI", "scDAI") {
        scsDai = _scsDAI;

        dai.safeApprove(C.SDAI, type(uint256).max);
        sDai.safeApprove(address(_scsDAI), type(uint256).max);
    }

    /**
     * @notice Returns the total amount of underlying assets held by the vault.
     * @return The total assets in DAI.
     */
    function totalAssets() public view override returns (uint256) {
        // Balance in sDAI
        uint256 balance = scsDai.convertToAssets(scsDai.balanceOf(address(this)));

        return sDai.convertToAssets(balance);
    }

    /**
     * @notice Hook called after a deposit is made.
     * @param assets The amount of assets deposited.
     */
    function afterDeposit(uint256 assets, uint256) internal override {
        // DAI => sDAI
        assets = sDai.deposit(assets, address(this));

        // Deposit sDAI to scSDAI
        scsDai.deposit(assets, address(this));
    }

    /**
     * @notice Withdraws assets from the vault.
     * @param assets The amount of assets to withdraw.
     * @param receiver The address to receive the withdrawn assets.
     * @param owner The address of the owner of the shares.
     * @return shares The amount of shares burned.
     */
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        // NOTE: copied and modified from ERC4626.sol with the highlighted changes below
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // change1: removed "beforeWithdraw(assets, shares);" here as it is not needed

        _burn(owner, shares);

        // change2: removed "asset.safeTransfer(receiver, assets);" and replaced with "_withdrawDaiFromScSDai(...)" call
        assets = _withdrawDaiFromScSDai(assets, shares, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Redeems shares for assets.
     * @param shares The amount of shares to redeem.
     * @param receiver The address to receive the withdrawn assets.
     * @param owner The address of the owner of the shares.
     * @return assets The amount of assets withdrawn.
     */
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        _burn(owner, shares);

        assets = _withdrawDaiFromScSDai(assets, shares, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Internal function to withdraw DAI from scSDAI.
     * @param daiAmount The amount of DAI to withdraw.
     * @param receiver The address to receive the withdrawn DAI.
     * @return The amount of DAI withdrawn.
     */
    function _withdrawDaiFromScSDai(uint256 daiAmount, uint256, address receiver) internal returns (uint256) {
        uint256 sDaiAmount = sDai.convertToShares(daiAmount);

        scsDai.withdraw(sDaiAmount, address(this), address(this));

        // redeem sDAI for DAI
        return sDai.redeem(sDaiAmount, receiver, address(this));
    }
}
