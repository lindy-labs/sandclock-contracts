// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "../lib/Constants.sol";
import {Swapper} from "./Swapper.sol";
import {scUSDCPriceConverter} from "./priceConverter/ScUSDCPriceConverter.sol";
import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";

/**
 * @title Sandclock USDC Vault version 2
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @notice The v2 vault uses multiple lending markets to earn yield on USDC deposits and borrow WETH to stake.
 * @dev This vault uses Sandclock's leveraged WETH staking vault - scWETH.
 */
contract scUSDCv2 is scCrossAssetYieldVault {
    using Address for address;

    constructor(
        address _admin,
        address _keeper,
        ERC4626 _scWETH,
        scUSDCPriceConverter _priceConverter,
        Swapper _swapper
    )
        scCrossAssetYieldVault(
            _admin,
            _keeper,
            ERC20(C.USDC),
            _scWETH,
            _priceConverter,
            _swapper,
            "Sandclock Yield USDC",
            "scUSDC"
        )
    {}

    function _swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdcAmountOutMin)
        internal
        virtual
        override
        returns (uint256)
    {
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactInput.selector,
                targetToken,
                asset,
                _wethAmount,
                _usdcAmountOutMin,
                500 /* pool fee*/
            )
        );

        return abi.decode(result, (uint256));
    }

    function _swapAssetForExactTargetToken(uint256 _wethAmountOut) internal virtual override {
        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactOutput.selector,
                asset,
                targetToken,
                _wethAmountOut,
                type(uint256).max, // ignore slippage
                500 // pool fee
            )
        );
    }
}
