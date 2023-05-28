// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {InvalidSlippageTolerance} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../lib/Constants.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {sc4626} from "../sc4626.sol";

/// @notice Contract holding shared functionality for scUSDC vaults
abstract contract scUSDCBase is sc4626, IFlashLoanRecipient {
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);

    WETH public immutable weth;

    // leveraged (w)eth vault
    ERC4626 public immutable scWETH;

    // max slippage for swapping WETH -> USDC
    uint256 public slippageTolerance = 0.99e18; // 1% default

    constructor(
        address _admin,
        address _keeper,
        ERC20 _asset,
        WETH _weth,
        ERC4626 _scWETH,
        string memory _name,
        string memory _symbol
    ) sc4626(_admin, _keeper, _asset, _name, _symbol) {
        weth = _weth;
        scWETH = _scWETH;
    }

    /**
     * @notice Set the slippage tolerance for swapping WETH to USDC on Uniswap.
     * @param _newSlippageTolerance The new slippage tolerance value.
     */
    function setSlippageTolerance(uint256 _newSlippageTolerance) external {
        _onlyAdmin();

        if (_newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _newSlippageTolerance;

        emit SlippageToleranceUpdated(msg.sender, _newSlippageTolerance);
    }
}
