// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";
import {Constants as C} from "../lib/Constants.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IAdapter} from "./IAdapter.sol";
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {MainnetAddresses as MA} from "../../script/base/MainnetAddresses.sol";
import {ISinglePairPriceConverter} from "./priceConverter/IPriceConverter.sol";

// TODO: reorder constructor params
contract scUSDT is scCrossAssetYieldVault {
    using Address for address;

    constructor(address _admin, address _keeper, ISinglePairPriceConverter _priceConverter, Swapper _swapper)
        scCrossAssetYieldVault(
            "Sandclock USDT Vault",
            "scUSDT",
            ERC20(C.USDT),
            ERC4626(MA.SCWETHV2),
            _admin,
            _keeper,
            _priceConverter,
            _swapper
        )
    {}

    function _swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdtAmountOutMin)
        internal
        virtual
        override
        returns (uint256 usdtReceived)
    {
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactInput.selector, C.WETH, C.USDT, _wethAmount, _usdtAmountOutMin, 500
            )
        );

        usdtReceived = abi.decode(result, (uint256));
    }

    function _swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) internal virtual override {
        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactOutput.selector, C.USDT, C.WETH, _targetTokenAmountOut, type(uint256).max, 500
            )
        );
    }
}
