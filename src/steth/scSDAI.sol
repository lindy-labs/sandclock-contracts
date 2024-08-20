// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {scCrossAssetYieldVault} from "./scCrossAssetYieldVault.sol";
import {Constants as C} from "../lib/Constants.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {ISinglePairPriceConverter} from "./priceConverter/IPriceConverter.sol";
import {MainnetAddresses as MA} from "../../script/base/MainnetAddresses.sol";

contract scSDAI is scCrossAssetYieldVault {
    using Address for address;
    using SafeTransferLib for ERC20;

    ERC20 public constant dai = ERC20(C.DAI);
    ERC4626 public constant sDai = ERC4626(C.SDAI);

    bytes constant SWAP_PATH = abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI);

    constructor(address _admin, address _keeper, ISinglePairPriceConverter _priceConverter, Swapper _swapper)
        scCrossAssetYieldVault(
            "Sandclock SDAI Vault",
            "scSDAI",
            sDai,
            ERC4626(MA.SCWETHV2),
            _admin,
            _keeper,
            _priceConverter,
            _swapper
        )
    {
        dai.safeApprove(address(sDai), type(uint256).max);
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
                Swapper.uniswapSwapExactInputMultihop.selector, targetToken, _wethAmount, _sDaiAmountOutMin, SWAP_PATH
            )
        );

        uint256 daiReceived = abi.decode(result, (uint256));

        sDaiReceived = _swapDaiToSDai(daiReceived);
    }

    function _swapAssetForExactTargetToken(uint256 _wethAmountOut) internal virtual override {
        // unwrap all sdai to dai
        uint256 daiAmount = _swapSDaiToDai(asset.balanceOf(address(this)));

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactOutputMultihop.selector, C.DAI, _wethAmountOut, daiAmount, SWAP_PATH
            )
        );

        // remaining dai to sdai
        _swapDaiToSDai(dai.balanceOf(address(this)));
    }

    function _swapSDaiToDai(uint256 _sDaiAmount) internal returns (uint256) {
        return sDai.redeem(_sDaiAmount, address(this), address(this));
    }

    function _swapDaiToSDai(uint256 _daiAmount) internal returns (uint256) {
        return sDai.deposit(_daiAmount, address(this));
    }
}
