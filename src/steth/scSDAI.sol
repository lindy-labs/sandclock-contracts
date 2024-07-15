// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {scSkeleton} from "./scSkeleton.sol";
import {Constants as C} from "../lib/Constants.sol";
import {BaseV2Vault} from "./BaseV2Vault.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {IAdapter} from "./IAdapter.sol";
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {MainnetAddresses as M} from "../../script/base/MainnetAddresses.sol";
import {AmountReceivedBelowMin} from "../errors/scErrors.sol";

contract scSDAI is scSkeleton {
    using SafeTransferLib for ERC20;

    constructor(address _admin, address _keeper, PriceConverter _priceConverter, Swapper _swapper)
        scSkeleton(
            "Sandclock SDAI Vault",
            "scSDAI",
            ERC20(C.SDAI),
            ERC4626(M.SCWETHV2),
            _admin,
            _keeper,
            _priceConverter,
            _swapper
        )
    {
        ERC20(C.DAI).safeApprove(C.SDAI, type(uint256).max);
    }
}

contract scSDAIPriceConverter is PriceConverter {
    using FixedPointMathLib for uint256;

    ERC4626 constant sDai = ERC4626(C.SDAI);

    // Chainlink price feed (DAI -> ETH)
    AggregatorV3Interface public daiToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_DAI_ETH_PRICE_FEED);

    constructor() PriceConverter(M.MULTISIG) {}

    function targetTokenToAsset(uint256 _ethAmount) public view override returns (uint256) {
        uint256 daiAmount = _ethToDai(_ethAmount);

        return sDai.convertToShares(daiAmount);
    }

    function assetToTargetToken(uint256 _sDaiAmount) public view override returns (uint256) {
        uint256 daiAmount = sDai.convertToAssets(_sDaiAmount);

        return _daiToEth(daiAmount);
    }

    function _ethToDai(uint256 _ethAmount) internal view returns (uint256) {
        (, int256 daiPriceInEth,,,) = daiToEthPriceFeed.latestRoundData();

        return _ethAmount.divWadDown(uint256(daiPriceInEth));
    }

    function _daiToEth(uint256 _daiAmount) internal view returns (uint256) {
        (, int256 daiPriceInEth,,,) = daiToEthPriceFeed.latestRoundData();

        return _daiAmount.mulWadDown(uint256(daiPriceInEth));
    }
}

contract scSDAISwapper is Swapper {
    using SafeTransferLib for ERC20;

    /**
     * Swap exact amount  of Weth to sDai
     * @param _wethAmount amount of weth to swap
     * @param _sDaiAmountOutMin minimum amount of sDai to receive after the swap
     * @return sDaiReceived amount of sDai received.
     */
    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _sDaiAmountOutMin)
        external
        override
        returns (uint256 sDaiReceived)
    {
        // weth => usdc => dai
        uint256 daiAmount = uniswapSwapExactInputMultihop(
            C.WETH, _wethAmount, 1, abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
        );

        sDaiReceived = _swapDaiToSdai(daiAmount);

        if (sDaiReceived < _sDaiAmountOutMin) revert AmountReceivedBelowMin();
    }

    /**
     * Swap sdai to exact amount of weth
     * @param _sDaiAmountOutMaximum maximum amount of sDai to swap for weth
     * @param _wethAmountOut amount of weth to receive
     */
    function swapAssetForExactTargetToken(uint256 _sDaiAmountOutMaximum, uint256 _wethAmountOut) external override {
        // sdai => dai
        uint256 daiAmount = _swapSdaiToDai(_sDaiAmountOutMaximum);

        // dai => usdc => weth
        uniswapSwapExactOutputMultihop(
            C.DAI, _wethAmountOut, daiAmount, abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
        );

        // remaining dai to sdai
        _swapDaiToSdai(_daiBalance());
    }

    ////////////////////////////////// INTERNAL FUNCTIONS //////////////////////////////////////////////////////

    function _swapSdaiToDai(uint256 _sDaiAmount) internal returns (uint256) {
        return ERC4626(C.SDAI).redeem(_sDaiAmount, address(this), address(this));
    }

    function _swapDaiToSdai(uint256 _daiAmount) internal returns (uint256) {
        return ERC4626(C.SDAI).deposit(_daiAmount, address(this));
    }

    function _daiBalance() internal view returns (uint256) {
        return ERC20(C.DAI).balanceOf(address(this));
    }
}
