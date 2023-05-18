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

    address constant protocol = C.EULER_PROTOCOL;
    IEulerMarkets constant markets = IEulerMarkets(C.EULER_MARKETS);
    IEulerEToken constant eUsdc = IEulerEToken(C.EULER_EUSDC_TOKEN);
    IEulerDToken constant dWeth = IEulerDToken(C.EULER_DWETH_TOKEN);

    uint8 public constant id = 3;

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(protocol, type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(protocol, type(uint256).max);
        markets.enterMarket(0, address(C.USDC));
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
