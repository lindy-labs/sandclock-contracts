// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";

contract DWethv2 is MockERC20 {
    constructor() MockERC20("Mock DWeth", "death", 6) {}
}