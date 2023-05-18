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
import {OracleLib} from "../phase-2/OracleLib.sol";

contract WstEthToWethSwapRouter is BaseSwapRouter {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using Address for address;

    IwstETH constant wstETH = IwstETH(C.WSTETH);
    WETH public constant weth = WETH(payable(C.WETH));
    ERC20 public constant stEth = ERC20(C.STETH);

    // Curve pool for ETH-stETH
    ICurvePool constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);
    // external contracts
    OracleLib immutable oracleLib;

    constructor(OracleLib _oracleLib) {
        oracleLib = _oracleLib;
    }

    function from() public pure override returns (address) {
        return address(wstETH);
    }

    function to() public pure returns (address) {
        return address(weth);
    }

    /// @notice the default route for swapping
    /// @dev use curve for swapping
    /// @param amount amount of the from token to swap
    function swapDefault(uint256 amount, uint256 slippageTolerance) external {
        //  wstETH to stEth
        uint256 stEthAmount = wstETH.unwrap(amount == type(uint256).max ? wstETH.balanceOf(address(this)) : amount);
        // stETH to eth
        stEth.safeApprove(address(curvePool), stEthAmount);
        curvePool.exchange(1, 0, stEthAmount, oracleLib.stEthToEth(stEthAmount).mulWadDown(slippageTolerance));
        // eth to weth
        weth.deposit{value: address(this).balance}();
    }
}
