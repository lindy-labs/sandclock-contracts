// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

// import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// @notice OFT is an ERC-20 token that extends the OFTCore contract.
contract Sandy is OFT {
    constructor(
        address _lzEndpoint
        address _delegate
    ) OFT("Sandclock Sandy", "SANDY", _lzEndpoint, _delegate){}
}

