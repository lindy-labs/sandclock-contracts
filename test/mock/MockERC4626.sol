// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract MockERC4626 is ERC4626 {
    constructor(ERC20 _asset) ERC4626(_asset, "Mock ERC4626 Vault", "mERC4626") {}

    function totalAssets() public view virtual override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
