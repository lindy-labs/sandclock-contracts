// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockVault as Vault} from "../test/scLiquity.t.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockStabilityPool} from "../test/mock/MockStabilityPool.sol";
import {MockLiquityPriceFeed} from "../test/mock/MockLiquityPriceFeed.sol";
import {MockPriceFeed} from "../test/mock/MockPriceFeed.sol";
import {Mock0x} from "../test/mock/Mock0x.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (Vault v) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        MockERC20 underlying;
        MockERC20 lqty;
        Mock0x xrouter;
        MockStabilityPool stabilityPool;
        MockLiquityPriceFeed priceFeed;
        MockPriceFeed lusd2eth;

        vm.startBroadcast(deployerPrivateKey);

        underlying = new MockERC20("Mock LUSD", "LUSD", 18);
        lqty = new MockERC20("Mock LQTY", "LQTY", 18);
        xrouter = new Mock0x();
        priceFeed = new MockLiquityPriceFeed();
        stabilityPool = new MockStabilityPool(address(underlying), address(priceFeed));
        lusd2eth = new MockPriceFeed();
        lusd2eth.setPrice(935490589304841);
        v = new Vault(underlying, stabilityPool, lusd2eth, lqty, address(xrouter));

        vm.stopBroadcast();
    }
}
