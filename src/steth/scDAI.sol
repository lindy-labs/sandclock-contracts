// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../lib/Constants.sol";
import {scSDAI} from "./scSDAI.sol";

/**
 * @title Sandclock Dai Vault
 * @dev Wrapper ERC4626 contract to support DAI deposits & withdrawals on scSDAI
 * @notice deposit token -> DAI
 */
contract scDAI is ERC4626 {
    using SafeTransferLib for ERC20;

    ERC4626 public constant sdai = ERC4626(C.SDAI);

    ERC4626 public immutable scsDAI;

    constructor(ERC4626 _scsDAI) ERC4626(ERC20(C.DAI), "Sandclock Yield DAI", "scDAI") {
        scsDAI = _scsDAI;

        ERC20(C.DAI).safeApprove(C.SDAI, type(uint256).max);
        ERC20(C.SDAI).safeApprove(address(_scsDAI), type(uint256).max);
    }

    function totalAssets() public view override returns (uint256) {
        // balance in sDAI
        uint256 balance = scsDAI.convertToAssets(scsDAI.balanceOf(address(this)));

        return sdai.convertToAssets(balance);
    }

    function afterDeposit(uint256 assets, uint256) internal override {
        // dai => sdai
        assets = sdai.deposit(assets, address(this));

        // depost sDAI to scSDAI
        scsDAI.deposit(assets, address(this));
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        _burn(owner, shares);

        assets = _withdrawDAIFromScSDAI(assets, shares, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        _burn(owner, shares);

        assets = _withdrawDAIFromScSDAI(assets, shares, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _withdrawDAIFromScSDAI(uint256 assets, uint256, address receiver) internal returns (uint256) {
        // assets is in DAI, we need it in SDAI
        uint256 assetsInSdai = sdai.convertToShares(assets);

        // withdraw required sDAI from scSDAI vault
        scsDAI.withdraw(assetsInSdai, address(this), address(this));

        // swap sDAI to DAI
        return sdai.redeem(assetsInSdai, receiver, address(this));
    }
}
