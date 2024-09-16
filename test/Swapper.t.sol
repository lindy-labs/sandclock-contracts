// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {Constants as C} from "../src/lib/Constants.sol";

import {Swapper} from "../src/steth/swapper/Swapper.sol";

contract SwapperTest is Test {
    using Address for address;

    Swapper swapper;
    IwstETH wstEth;

    constructor() {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19880300);

        wstEth = IwstETH(C.WSTETH);
        swapper = new Swapper();

        ERC20(C.DAI).approve(C.SDAI, type(uint256).max);
    }

    function test_uniswapSwapExactInput() public {
        uint256 usdcBalance = 100_000e6;
        deal(C.USDC, address(this), usdcBalance);

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(swapper.uniswapSwapExactInput.selector, C.USDC, C.WETH, usdcBalance, 20 ether, 500)
        );

        uint256 wethReceived = abi.decode(result, (uint256));

        assertEq(ERC20(C.USDC).balanceOf(address(this)), 0, "usdc balance not spent");
        assertEq(ERC20(C.WETH).balanceOf(address(this)), wethReceived, "weth balance should be equal to wethReceived");
    }

    function test_uniswapSwapExactOutput() public {
        uint256 usdcBalance = 100_000e6;
        deal(C.USDC, address(this), usdcBalance);
        uint256 ethToBuy = 25 ether;

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(swapper.uniswapSwapExactOutput.selector, C.USDC, C.WETH, ethToBuy, usdcBalance, 500)
        );

        uint256 usdcSpent = abi.decode(result, (uint256));

        assertEq(ERC20(C.USDC).balanceOf(address(this)), usdcBalance - usdcSpent, "usdc balance not spent");
        assertEq(ERC20(C.WETH).balanceOf(address(this)), ethToBuy, "weth balance should be equal to wethReceived");
    }

    function test_uniswapSwapExactInputMultihop() public {
        uint256 daiBalance = 100_000 ether;
        deal(C.DAI, address(this), daiBalance);

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                swapper.uniswapSwapExactInputMultihop.selector,
                C.DAI,
                daiBalance,
                20 ether,
                abi.encodePacked(C.DAI, uint24(100), C.USDC, uint24(500), C.WETH)
            )
        );

        uint256 wethReceived = abi.decode(result, (uint256));

        assertEq(ERC20(C.WETH).balanceOf(address(this)), wethReceived, "weth balance should be equal to wethReceived");
        assertEq(ERC20(C.DAI).balanceOf(address(this)), 0, "dai balance not spent");
    }

    function test_uniswapSwapExactOutputMultihop() public {
        uint256 daiBalance = 100_000 ether;
        deal(C.DAI, address(this), daiBalance);
        uint256 ethToBuy = 20 ether;

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                swapper.uniswapSwapExactOutputMultihop.selector,
                C.DAI,
                ethToBuy,
                daiBalance, // amount in maximum
                abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI)
            )
        );

        uint256 daiSpent = abi.decode(result, (uint256));

        assertEq(ERC20(C.DAI).balanceOf(address(this)), daiBalance - daiSpent, "dai balance");
        assertEq(ERC20(C.WETH).balanceOf(address(this)), ethToBuy, "weth balance should be equal to wethReceived");
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

    receive() external payable {}
}
