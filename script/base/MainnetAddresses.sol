// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

/**
 * Library containing the addresses for all the deployed contracts on Ethereum Mainnet
 */
library MainnetAddresses {
    address public constant QUARTZ = 0xbA8A621b4a54e61C442F5Ec623687e2a942225ef;

    address public constant SCWETHV2 = 0x4c406C068106375724275Cbff028770C544a1333;
    address public constant SCWETHV2_MORPHO_ADAPTER = 0x4420F0E6A38863330FD4885d76e1265DAD5aa9df;
    address public constant SCWETHV2_COMPOUND_ADAPTER = 0x379022F4d2619c7fbB95f9005ea0897e3a31a0C4;
    address public constant SCWETHV2_AAVEV3_ADAPTER = 0x99C55166Dc78a96C52caf1dB201C0eB0086fB83E;

    address public constant SCUSDCV2 = 0x096697720056886b905D0DEB0f06AfFB8e4665E5;
    address public constant SCUSDCV2_MORPHO_ADAPTER = 0x92803F0E528c3F5053A1aBF1f0f2AeC45751a189;
    address public constant SCUSDCV2_AAVEV2_ADAPTER = 0xE0E9E98FD963C2e69718C76939924522A9646885;
    address public constant SCUSDCV2_AAVEV3_ADAPTER = 0xf59c324fF111D86894f175E22B70b0d54998ff3E;

    address public constant PRICE_CONVERTER = 0xD76B0Ff4A487CaFE4E19ed15B73f12f6A92095Ca;
    address public constant SWAPPER = 0x6649f12b5ef495a3861b21E3206B1AbfA33A6531;

    address public constant KEEPER = 0x397502F15E11C524F23C0c003f5E8004C1c5c71D;

    address public constant MULTISIG = 0x6cF38285FdFAf8D67205ca444A899025b5B18e83;
    // TODO: TREASURY == MULTISIG for now, change to the staking contract address once it's deployed
    address public constant TREASURY = MULTISIG;

    // used on some earlier deploys
    address public constant OLD_MULTISIG = 0x035F210e5d14054E8AE5A6CFA76d643aA200D56E;
    address public constant OLD_KEEPER = 0x06444B9F0c6a966b8B9Bc1e808d2B165a87e3a38;
}
