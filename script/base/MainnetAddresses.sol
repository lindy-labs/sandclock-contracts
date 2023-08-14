// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

/**
 * Library containing the addresses for all the deployed contracts on Ethereum Mainnet
 */
library MainnetAddresses {
    address public constant SCWETHV2 = 0x4B68d2D0E94240481003Fc3Fd10ffB663b081c3D;
    address public constant SCWETHV2_MORPHO_ADAPTER = 0x8532C8F0582584b83763c287a55bdE5552C5bF35;
    address public constant SCWETHV2_COMPOUND_ADAPTER = 0x379022F4d2619c7fbB95f9005ea0897e3a31a0C4;

    address public constant SCUSDCV2 = 0xbb6EE8bE110602a05F268AcCFC46d55bd87DFB82;
    address public constant SCUSDCV2_MORPHO_ADAPTER = 0x92803F0E528c3F5053A1aBF1f0f2AeC45751a189;
    address public constant SCUSDCV2_AAVEV2_ADAPTER = 0xE0E9E98FD963C2e69718C76939924522A9646885;

    address public constant PRICE_CONVERTER = 0xD76B0Ff4A487CaFE4E19ed15B73f12f6A92095Ca;
    address public constant SWAPPER = 0x6649f12b5ef495a3861b21E3206B1AbfA33A6531;
}