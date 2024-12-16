// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {Sandy} from "src/Sandy.sol";

contract DeploySandy is MainnetDeployBase {
    address public constant BASE_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address public constant ARBITRUM_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32 public constant BASE_EID = 30184;
    uint32 public constant ARBITRUM_EID = 30110;

    address public constant SANDY = 0x32d2c278c8d5407Fb52fDC6Dc217Ea7eed7E67BC;

    function run() external returns (Sandy sandy) {
        vm.startBroadcast(deployerAddress);

        // sandy = Sandy(
        //     deployWithCreate3(
        //         type(Sandy).name,
        //         abi.encodePacked(type(Sandy).creationCode, abi.encode(POLYGON_ENDPOINT, deployerAddress))
        //     )
        // );

        sandy = Sandy(SANDY);

        console2.log(sandy.isPeer(BASE_EID, addressToBytes32(SANDY)));

        vm.stopBroadcast();
    }

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
