// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {Constants as C} from "../src/lib/Constants.sol";

import {Swapper} from "../src/steth/Swapper.sol";

contract SwapperTest is Test {
    using Address for address;

    Swapper swapper;
    IwstETH wstEth;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19880300);

        wstEth = IwstETH(C.WSTETH);
        swapper = new Swapper();

        ERC20(C.DAI).approve(C.SDAI, type(uint256).max);
    }

    function test_uniswapSwapExactOutputMultihop() public {
        // dai to weth
        uint256 daiAmount = 100_000 ether;
        deal(C.DAI, address(this), daiAmount);

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                swapper.uniswapSwapExactOutputMultihop.selector,
                C.DAI,
                2 ether,
                daiAmount,
                abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
            )
        );

        uint256 wethReceived = abi.decode(result, (uint256));

        console.log("wethReceived", wethReceived);
    }

    function test_lidoSwapWethToWstEth_usesCurveForSmallAmounts() public {
        uint256 wethAmount = 10 ether;
        deal(C.WETH, address(this), wethAmount);

        // expect a call to curvePool.exchange
        vm.expectCall(
            address(swapper.curvePool()), abi.encodeCall(swapper.curvePool().exchange, (0, 1, wethAmount, wethAmount))
        );

        // execute the swap
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(swapper.lidoSwapWethToWstEth.selector, wethAmount)
        );

        uint256 wstEthAmountReceived = abi.decode(result, (uint256));

        assertEq(
            wstEthAmountReceived,
            wstEth.balanceOf(address(this)),
            "wstEth amount received should be equal to wstEth balance"
        );

        uint256 stEthAmountReceived = wstEth.unwrap(wstEthAmountReceived);

        // when using curve, the amount should be greater than the weth amount
        assertTrue(stEthAmountReceived > wethAmount, "stEthAmount should be greater than wethAmount");
    }

    function test_lidoSwapWethToWstEth_usesLidoForBiggerAmounts() public {
        uint256 wethAmount = 5000 ether;
        deal(C.WETH, address(this), wethAmount);

        // expect a call to stEth.submit
        vm.expectCall(address(C.STETH), wethAmount, abi.encodeCall(ILido.submit, address(0)));

        // execute the swap
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(swapper.lidoSwapWethToWstEth.selector, wethAmount)
        );

        uint256 wstEthAmountReceived = abi.decode(result, (uint256));

        assertEq(
            wstEthAmountReceived,
            wstEth.balanceOf(address(this)),
            "wstEth amount received should be equal to wstEth balance"
        );

        uint256 stEthAmountReceived = wstEth.unwrap(wstEthAmountReceived);

        // when using lido, stEth received should be equal to weth amount (with possible rounding errors)
        assertApproxEqAbs(stEthAmountReceived, wethAmount, 2, "stEthAmount should be equal to wethAmount");
    }

    function test_swapWethToSdai() public {
        uint256 wethAmount = 1000 ether;
        deal(C.WETH, address(this), wethAmount);

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(swapper.swapWethToSdai.selector, wethAmount, 1)
        );

        uint256 sdaiReceived = abi.decode(result, (uint256));

        assertEq(sdaiReceived, 2769454163646490100581023, "weth to sdai swap error");
    }

    function test_swapSdaiForExactWeth() public {
        uint256 sDaiAmount = 100000 ether;
        deal(C.SDAI, address(this), sDaiAmount);

        uint256 wethToReceive = 7 ether;

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(swapper.swapSdaiForExactWeth.selector, sDaiAmount, wethToReceive)
        );

        uint256 wethReceived = ERC20(C.WETH).balanceOf(address(this));

        assertEq(wethReceived, wethToReceive);
    }

    receive() external payable {}
}
