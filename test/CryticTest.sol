pragma solidity ^0.8.0;

import {CryticERC4626PropertyTests} from "properties/ERC4626/ERC4626PropertyTests.sol";
import {TestERC20Token} from "properties/ERC4626/util/TestERC20Token.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
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
    address _keeper = address(0x05);
    uint256 _slippageTolerance = 0.99e18;
    uint256 _targetLtv = 0.7e18;

    constructor() {
        hevm.roll(16771449); // sets the correct block number
        hevm.warp(1678131671); // sets the expected timestamp for the block number
        TestERC20Token _asset = new TestERC20Token("Test WETH", "TW", 18);

        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: _admin,
            keeper: _keeper,
            targetLtv: 0.7e18,
            slippageTolerance: 0.99e18,
            aavePool: IPool(C.AAVE_POOL),
            aaveAwstEth: IAToken(C.AAVE_AWSTETH_TOKEN),
            aaveVarDWeth: ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN),
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: address(_asset),
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        scWETH _vault = new scWETH(scWethParams);
        initialize(address(_vault), address(_vault.asset()), false);
    }
}
