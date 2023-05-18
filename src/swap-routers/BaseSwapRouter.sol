// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {ISwapRouter} from "./ISwapRouter.sol";
import {Constants as C} from "../lib/Constants.sol";

abstract contract BaseSwapRouter is ISwapRouter {
    using SafeTransferLib for ERC20;
    using Address for address;

    function from() public pure virtual returns (address);

    function swap0x(bytes calldata swapData, uint256 amount) external virtual {
        ERC20(from()).safeApprove(C.ZEROX_ROUTER, amount);
        C.ZEROX_ROUTER.functionCall(swapData);

        // todo: add minimum Amount Out check if required
    }
}
