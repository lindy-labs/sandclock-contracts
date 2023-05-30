// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {PriceConverter} from "../src/steth/PriceConverter.sol";
import "../src/errors/scErrors.sol";
import {FaultyAdapter} from "./mocks/adapters/FaultyAdapter.sol";

contract PriceConverterTest is Test {
    using FixedPointMathLib for uint256;

    event UsdcToEthPriceFeedUpdated(address indexed admin, address newPriceFeed);

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    PriceConverter priceConverter;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17243956);

        priceConverter = new PriceConverter(address(this));
    }

    function test_constructor() public {
        assertEq(address(priceConverter.usdcToEthPriceFeed()), C.CHAINLINK_USDC_ETH_PRICE_FEED, "wrong price feed");

        assertTrue(priceConverter.hasRole(priceConverter.DEFAULT_ADMIN_ROLE(), address(this)), "admin role not set");
    }

    function test_setUsdcToEthPriceFeed_FailsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        priceConverter.setUsdcToEthPriceFeed(AggregatorV3Interface(address(0)));
    }

    function test_setUsdcToEthPriceFeed_FailsIfNewPriceFeedIsZeroAddress() public {
        vm.expectRevert(PriceFeedZeroAddress.selector);
        priceConverter.setUsdcToEthPriceFeed(AggregatorV3Interface(address(0)));
    }

    function test_setUsdcToEthPriceFeed_ChangesThePriceFeed() public {
        AggregatorV3Interface _newPriceFeed = AggregatorV3Interface(address(0x1));

        priceConverter.setUsdcToEthPriceFeed(_newPriceFeed);

        assertEq(address(priceConverter.usdcToEthPriceFeed()), address(_newPriceFeed), "price feed has not changed");
    }

    function test_setUsdcToEthPriceFeed_EmitsEvent() public {
        AggregatorV3Interface _newPriceFeed = AggregatorV3Interface(address(0x1));

        vm.expectEmit(true, true, true, true);
        emit UsdcToEthPriceFeedUpdated(address(this), address(_newPriceFeed));

        priceConverter.setUsdcToEthPriceFeed(_newPriceFeed);
    }
}
