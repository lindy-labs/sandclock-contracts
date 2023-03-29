pragma solidity ^0.8.0;

import {CryticERC4626PropertyTests} from "properties/ERC4626/ERC4626PropertyTests.sol";
import {TestERC20Token} from "properties/ERC4626/util/TestERC20Token.sol";
import {scWETH} from "../src/steth/scWETH.sol";

interface Hevm {
    function prank(address) external;
    function roll(uint256) external;
    function warp(uint256) external;
}

contract CryticERC4626InternalHarness is CryticERC4626PropertyTests {
    address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
    Hevm hevm = Hevm(HEVM_ADDRESS);
    address _admin = address(this);
    uint256 _slippageTolerance = 0.99e18;
    uint256 _targetLtv = 0.7e18;

    constructor() {
        hevm.roll(16771449); // sets the correct block number
        hevm.warp(1678131671); // sets the expected timestamp for the block number
        TestERC20Token _asset = new TestERC20Token("Test Token", "TT", 18);
        scWETH _vault = new scWETH(address(_asset), _admin, _targetLtv, _slippageTolerance);
        initialize(address(_vault), address(_asset), false);
    }
}
