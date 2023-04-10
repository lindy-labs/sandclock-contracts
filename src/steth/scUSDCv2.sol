// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";

import {Constants as C} from "../lib/Constants.sol";
import {CErc20} from "../interfaces/compound/CErc20.sol";
import {CEther} from "../interfaces/compound/CEther.sol";
import {Comptroller} from "../interfaces/compound/Comptroller.sol";

// TODO: probably don't need this to be a new contract
contract scUSDCv2 {
    using FixedPointMathLib for uint256;

    ERC20 public usdc = ERC20(C.USDC);
    WETH public weth = WETH(payable(C.WETH));

    Comptroller public comptroller = Comptroller(C.COMPTROLLER);
    CErc20 public cUsdc = CErc20(C.C_USDC);
    CEther public cEth = CEther(C.C_ETH);

    IPool public immutable aavePool = IPool(C.AAVE_POOL);
    IAToken public immutable aUsdc = IAToken(C.AAVE_AUSDC_TOKEN);
    ERC20 public immutable dWeth = ERC20(C.AAVE_VAR_DEBT_WETH_TOKEN);

    constructor() {
        usdc.approve(C.C_USDC, type(uint256).max);
        weth.approve(C.C_ETH, type(uint256).max);
        usdc.approve(C.AAVE_POOL, type(uint256).max);
        weth.approve(C.AAVE_POOL, type(uint256).max);

        address[] memory cTokens = new address[](2);
        cTokens[0] = C.C_USDC;
        cTokens[1] = C.C_ETH;
        comptroller.enterMarkets(cTokens);
    }

    struct RebalanceParams {
        uint256 aaveV3CollateralAllocationPct;
        uint256 aaveV3TargetLtv;
        uint256 compoundV2CollateralAllocationPct;
        uint256 compoundV2TargetLtv;
    }

    function rebalance(RebalanceParams memory _params) external {
        uint256 totalCollateral = getTotalCollateral();
        uint256 aaveV3Supply = totalCollateral.mulWadDown(_params.aaveV3CollateralAllocationPct);
        uint256 compoundV2Supply = totalCollateral.mulWadDown(_params.compoundV2CollateralAllocationPct);

        aavePool.supply(address(usdc), aaveV3Supply, address(this), 0);
        uint256 mintResult = cUsdc.mint(compoundV2Supply);
    }

    function getTotalCollateral() public returns (uint256) {
        return aUsdc.balanceOf(address(this)) + cUsdc.balanceOfUnderlying(address(this)) + usdc.balanceOf(address(this));
    }
}
