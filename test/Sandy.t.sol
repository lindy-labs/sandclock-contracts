// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import "forge-std/console2.sol";
import "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingReceipt, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {Sandy} from "src/Sandy.sol";

contract SandyTest is Test {
    uint256 mainnetFork;

    address public constant BASE_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address public constant ARBITRUM_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32 public constant BASE_EID = 30184;
    uint32 public constant ARBITRUM_EID = 30110;

    address public constant SANDY = 0x32d2c278c8d5407Fb52fDC6Dc217Ea7eed7E67BC;

    Sandy sandy = Sandy(SANDY);

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_ARBITRUM"));
        vm.selectFork(mainnetFork);
        vm.rollFork(21413348);
    }

    function test_sandy() public {
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ARBITRUM_ENDPOINT);

        endpoint.getConfig(SANDY, 0x7B9E184e07a6EE1aC23eAe0fe8D6Be2f663f05e6, BASE_EID, 2);

        // from arbitrum to base
        // SendParam memory sendParam = SendParam({
        //     dstEid: BASE_EID,
        //     to: addressToBytes32(0xeF025519c9aeae8d60EB19B7E18bDDD6d3f08c5e),
        //     amountLD: 10e18,
        //     minAmountLD: 10e18,
        //     extraOptions: "",
        //     composeMsg: "",
        //     oftCmd: ""
        // });

        // MessagingFee memory msgFee = sandy.quoteSend(sendParam, false);

        // console2.log("Native Fee", msgFee.nativeFee);
    }

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
