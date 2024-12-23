// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingReceipt, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {Sandy} from "src/Sandy.sol";

contract DeploySandy is MainnetDeployBase {
    struct SetConfigParam {
        uint32 eid;
        uint32 configType;
        bytes config;
    }

    // struct EnforcedOptionParam {
    //     uint32 eid; // Endpoint ID
    //     uint16 msgType; // Message Type
    //     bytes options; // Additional options
    // }

    address public constant BASE_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address public constant ARBITRUM_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    address public constant ARBITRUM_SEPOLIA_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address public constant BASE_SEPOLIA_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;

    uint32 public constant BASE_EID = 30184;
    uint32 public constant ARBITRUM_EID = 30110;

    uint32 public constant ARBITRUM_SEPOLIA_EID = 421614;
    uint32 public constant BASE_SEPOLIA_EID = 84532;

    address public constant SANDY = 0x32d2c278c8d5407Fb52fDC6Dc217Ea7eed7E67BC;

    function run() external returns (Sandy sandy) {
        vm.startBroadcast(deployerAddress);

        // sandy = Sandy(
        //     deployWithCreate3(
        //         type(Sandy).name,
        //         abi.encodePacked(type(Sandy).creationCode, abi.encode(ARBITRUM_SEPOLIA_ENDPOINT, deployerAddress))
        //     )
        // );

        sandy = Sandy(SANDY);

        // bytes memory enforcedOptionBytes = hex"0003010011010000000000000000000000000000ea60";

        // EnforcedOptionParam memory enforcedOptionParam = EnforcedOptionParam(30110, 1, enforcedOptionBytes);

        // EnforcedOptionParam[] memory enforcedOptionParams = new EnforcedOptionParam[](1);
        // enforcedOptionParams[0] = enforcedOptionParam;

        // sandy.setEnforcedOptions(enforcedOptionParams);

        // ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ARBITRUM_ENDPOINT);

        // endpoint.setConfig(SANDY, 0x7B9E184e07a6EE1aC23eAe0fe8D6Be2f663f05e6, BASE_EID, 2);

        // from arbitrum to base
        SendParam memory sendParam = SendParam({
            dstEid: ARBITRUM_EID,
            to: addressToBytes32(0x3Ab6EBDBf08e1954e69F6859AdB2DA5236D2e838),
            amountLD: 999e18,
            minAmountLD: 999e18,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory msgFee = sandy.quoteSend(sendParam, false);

        console2.log("Native Fee", msgFee.nativeFee);

        sandy.send{value: msgFee.nativeFee}(sendParam, msgFee, deployerAddress);

        vm.stopBroadcast();
    }

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
