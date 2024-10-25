// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../lib/Constants.sol";
import {IDaiUsds} from "../interfaces/sky/IDaiUsds.sol";

/**
 * @title scUSDS
 * @notice Sandclock USDS Vault
 * @dev A wrapper ERC4626 Vault that swaps the usds to dai and deposits dai to scDAI Vault.
 */
contract scUSDS is ERC4626 {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;

    /// @notice The DAI ERC20 token contract.
    ERC20 public constant dai = ERC20(C.DAI);

    /// @notice The sDAI ERC4626 token contract.
    ERC4626 public constant sDai = ERC4626(C.SDAI);

    /// @notice The USDS ERC20 token contract.
    ERC20 public constant usds = ERC20(C.USDS);

    /// @notice The Dai - USDS converter contract from sky
    IDaiUsds public constant converter = IDaiUsds(C.DAI_USDS_CONVERTER);

    /// @notice The scSDAI ERC4626 vault contract.
    ERC4626 public immutable scsDai;

    constructor(ERC4626 _scsDai) ERC4626(usds, "Sandclock Yield USDS", "scUSDS") {
        scsDai = _scsDai;

        dai.safeApprove(C.DAI_USDS_CONVERTER, type(uint256).max);
        usds.safeApprove(C.DAI_USDS_CONVERTER, type(uint256).max);

        dai.safeApprove(C.SDAI, type(uint256).max);
        sDai.safeApprove(address(_scsDai), type(uint256).max);
    }

    /**
     * @notice Returns the total amount of underlying assets held by the vault.
     * @return The total assets in USDS.
     */
    function totalAssets() public view override returns (uint256) {
        // balance in sDai
        uint256 balance = scsDai.convertToAssets(scsDai.balanceOf(address(this)));

        // returns balance in DAI
        // usds to dai conversion rate is 1:1
        return sDai.convertToAssets(balance);
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

        // change2: removed "asset.safeTransfer(receiver, assets);" and replaced with "_withdrawUsdsFromScSDai(...)" call
        _withdrawUsdsFromScSDai(assets, shares, receiver);

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

        _withdrawUsdsFromScSDai(assets, shares, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    ////////////////////////////////// INTERNAL METHODS ////////////////////////////////

    /**
     * @notice Hook called after a deposit is made.
     * @param assets The amount of usds deposited.
     */
    function afterDeposit(uint256 assets, uint256) internal override {
        // USDS => DAI
        converter.usdsToDai(address(this), assets);

        // DAI => SDAI
        assets = sDai.deposit(assets, address(this));

        // Deposit SDAI to scsDai
        scsDai.deposit(assets, address(this));
    }

    /**
     * @notice withdraws the required sdai amount from scSDAI and converts it to usds
     * @param usdsAmount Amount of usds to withdraw
     * @param receiver The address to receive the withdrawn USDS
     */
    function _withdrawUsdsFromScSDai(uint256 usdsAmount, uint256, address receiver) internal {
        uint256 sDaiAmount = sDai.convertToShares(usdsAmount);

        scsDai.withdraw(sDaiAmount, address(this), address(this));

        // sdai => dai
        sDai.redeem(sDaiAmount, address(this), address(this));

        // dai => usds
        converter.daiToUsds(receiver, dai.balanceOf(address(this)));
    }
}
