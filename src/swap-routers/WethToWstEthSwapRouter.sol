// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {BaseSwapRouter} from "./BaseSwapRouter.sol";

import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Constants as C} from "../lib/Constants.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";

contract WethToWstEthSwapRouter is BaseSwapRouter {
    using Address for address;
    using SafeTransferLib for ERC20;

    IwstETH constant wstETH = IwstETH(C.WSTETH);
    WETH public constant weth = WETH(payable(C.WETH));
    ILido public constant stEth = ILido(C.STETH);
    // Curve pool for ETH-stETH
    ICurvePool constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);

    function from() public pure override returns (address) {
        return address(weth);
    }

    function to() public pure returns (address) {
        return address(wstETH);
    }

    /// @notice the default route for swapping
    /// @dev use curve for swapping
    /// @param amount amount of the from token to swap
    function swapDefault(uint256 amount, uint256) external {
        // weth to eth
        weth.withdraw(amount);
        // stake to lido / eth => stETH
        stEth.submit{value: amount}(address(0x00));
        //  stETH to wstEth
        uint256 stEthBalance = stEth.balanceOf(address(this));
        ERC20(address(stEth)).safeApprove(address(wstETH), stEthBalance);
        wstETH.wrap(stEthBalance);
    }
}
