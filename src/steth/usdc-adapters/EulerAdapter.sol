// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IEulerMarkets, IEulerEToken, IEulerDToken} from "lib/euler-interfaces/contracts/IEuler.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {IAdapter} from "./IAdapter.sol";

contract EulerAdapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    // address of the EULER protocol contract
    address public constant protocol = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    // address of the EULER markets contract
    IEulerMarkets public constant markets = IEulerMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    // address of the EULER eUSDC token contract (supply token)
    IEulerEToken public constant eUsdc = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    // address of the EULER eWETH token contract (debt token)
    IEulerDToken public constant dWeth = IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    uint8 public constant id = 3;

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(protocol, type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(protocol, type(uint256).max);
        markets.enterMarket(0, address(C.USDC));
    }

    function revokeApprovals() external override {
        ERC20(C.USDC).safeApprove(protocol, 0);
        WETH(payable(C.WETH)).safeApprove(protocol, 0);
    }

    function supply(uint256 _amount) external override {
        eUsdc.deposit(0, _amount);
    }

    function borrow(uint256 _amount) external override {
        dWeth.borrow(0, _amount);
    }

    function repay(uint256 _amount) external override {
        dWeth.repay(0, _amount);
    }

    function withdraw(uint256 _amount) external override {
        eUsdc.withdraw(0, _amount);
    }

    function getCollateral(address _account) external view override returns (uint256) {
        return eUsdc.balanceOfUnderlying(_account);
    }

    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }
}
