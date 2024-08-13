// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {scSkeleton} from "./scSkeleton.sol";
import {Constants as C} from "../lib/Constants.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {MainnetAddresses as MA} from "../../script/base/MainnetAddresses.sol";

contract scSDAI is scSkeleton {
    using Address for address;
    using SafeTransferLib for ERC20;

    constructor(address _admin, address _keeper, PriceConverter _priceConverter, Swapper _swapper)
        scSkeleton(
            "Sandclock SDAI Vault",
            "scSDAI",
            ERC20(C.SDAI),
            ERC4626(MA.SCWETHV2),
            _admin,
            _keeper,
            _priceConverter,
            _swapper
        )
    {
        ERC20(C.DAI).safeApprove(C.SDAI, type(uint256).max);
    }

    function _swapTargetTokenForAsset(uint256 _wethAmount, uint256 _sDaiAmountOutMin)
        internal
        virtual
        override
        returns (uint256 sDaiReceived)
    {
        // weth => usdc => dai
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactInputMultihop.selector,
                targetToken,
                _wethAmount,
                _sDaiAmountOutMin,
                abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
            )
        );

        uint256 daiReceived = abi.decode(result, (uint256));

        sDaiReceived = _swapDaiToSdai(daiReceived);
    }

    function _swapAssetForExactTargetToken(uint256 _wethAmountOut) internal virtual override {
        // sdai => dai
        uint256 daiAmount = _swapSdaiToDai(asset.balanceOf(address(this)));

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactOutputMultihop.selector,
                C.DAI,
                _wethAmountOut,
                daiAmount,
                abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
            )
        );

        // remaining dai to sdai
        _swapDaiToSdai(_daiBalance());
    }

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

contract scSDAIPriceConverter is PriceConverter {
    using FixedPointMathLib for uint256;

    ERC4626 constant sDai = ERC4626(C.SDAI);

    // Chainlink price feed (DAI -> ETH)
    AggregatorV3Interface public daiToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_DAI_ETH_PRICE_FEED);

    constructor() PriceConverter(MA.MULTISIG) {}

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
