#!/bin/bash
cd ../..
if [ "$#" -eq 0 ]
then 
  certoraRun  certora/harness/scUSDC.sol \
              certora/harness/scWETH.sol \
              lib/solmate/src/tokens/WETH.sol \
              certora/mocks/AaveUsdcPool.sol \
              certora/mocks/AaveWethPool.sol \
              certora/mocks/AUsdc.sol \
              certora/mocks/AWeth.sol \
              certora/mocks/DUsdc.sol \
              certora/mocks/DWeth.sol \
              certora/mocks/USDC.sol \
              certora/mocks/WstETH.sol \
              certora/mocks/StETH.sol \
              certora/mocks/CurvePool.sol \
              certora/mocks/SwapRouter.sol \
              certora/mocks/AggregatorV3.sol \
              certora/mocks/BalancerVault.sol \
    --link scUSDC:asset=USDC \
    --link scUSDC:weth=WETH \
    --link scUSDC:dWeth=DWeth \
    --link scUSDC:usdc=USDC \
    --link scUSDC:swapRouter=SwapRouter \
    --link scUSDC:usdcToEthPriceFeed=AggregatorV3 \
    --link scUSDC:scWETH=scWETH \
    --link scUSDC:aavePool=AaveUsdcPool \
    --link scUSDC:balancerVault=BalancerVault \
    --link scUSDC:aUsdc=AUsdc \
    --link scWETH:asset=WETH \
    --link scWETH:aavePool=AaveWethPool \
    --link scWETH:aToken=AWeth \
    --link scWETH:variableDebtToken=DUsdc \
    --link scWETH:weth=WETH \
    --link scWETH:wstETH=WstETH \
    --link scWETH:stEth=StETH \
    --link scWETH:curvePool=CurvePool \
    --link scWETH:stEThToEthPriceFeed=AggregatorV3 \
    --link scWETH:balancerVault=BalancerVault \
    --link WstETH:stETH=StETH \
    --link AaveUsdcPool:aToken=AUsdc \
    --link AaveUsdcPool:variableDebtToken=DUsdc \
    --link AaveWethPool:aToken=AWeth \
    --link AaveWethPool:variableDebtToken=DWeth \
    --link AWeth:underlying=WETH \
    --link AUsdc:underlying=USDC \
    --verify scUSDC:certora/specs/scUSDC.spec \
    --optimistic_loop \
    --smt_timeout 3600 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
                aave-v3=lib/aave-v3-core/contracts \
    --settings -optimisticFallback=true,-smt_nonLinearArithmetic=true,-t=3600,-prettifyCEX=none,-multipleCEX=none \
    --msg "verifying scUSDC"
elif [ "$#" -eq 1 ]
then
  certoraRun  certora/harness/scUSDC.sol \
              certora/harness/scWETH.sol \
              lib/solmate/src/tokens/WETH.sol \
              certora/mocks/AaveUsdcPool.sol \
              certora/mocks/AaveWethPool.sol \
              certora/mocks/AUsdc.sol \
              certora/mocks/AWeth.sol \
              certora/mocks/DUsdc.sol \
              certora/mocks/DWeth.sol \
              certora/mocks/USDC.sol \
              certora/mocks/WstETH.sol \
              certora/mocks/StETH.sol \
              certora/mocks/CurvePool.sol \
              certora/mocks/SwapRouter.sol \
              certora/mocks/AggregatorV3.sol \
              certora/mocks/BalancerVault.sol \
    --link scUSDC:asset=USDC \
    --link scUSDC:weth=WETH \
    --link scUSDC:dWeth=DWeth \
    --link scUSDC:usdc=USDC \
    --link scUSDC:swapRouter=SwapRouter \
    --link scUSDC:usdcToEthPriceFeed=AggregatorV3 \
    --link scUSDC:scWETH=scWETH \
    --link scUSDC:aavePool=AaveUsdcPool \
    --link scUSDC:balancerVault=BalancerVault \
    --link scUSDC:aUsdc=AUsdc \
    --link scWETH:asset=WETH \
    --link scWETH:aavePool=AaveWethPool \
    --link scWETH:aToken=AWeth \
    --link scWETH:variableDebtToken=DUsdc \
    --link scWETH:weth=WETH \
    --link scWETH:wstETH=WstETH \
    --link scWETH:stEth=StETH \
    --link scWETH:curvePool=CurvePool \
    --link scWETH:stEThToEthPriceFeed=AggregatorV3 \
    --link scWETH:balancerVault=BalancerVault \
    --link WstETH:stETH=StETH \
    --link AaveUsdcPool:aToken=AUsdc \
    --link AaveUsdcPool:variableDebtToken=DUsdc \
    --link AaveWethPool:aToken=AWeth \
    --link AaveWethPool:variableDebtToken=DWeth \
    --link AWeth:underlying=WETH \
    --link AUsdc:underlying=USDC \
    --verify scUSDC:certora/specs/scUSDC.spec \
    --optimistic_loop \
    --smt_timeout 3600 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
                aave-v3=lib/aave-v3-core/contracts \
    --settings -optimisticFallback=true,-smt_nonLinearArithmetic=true,-t=3600,-prettifyCEX=none,-multipleCEX=none \
    --rule "$1" \
    --msg "verifying rule $1 for scUSDC"
else
  echo "You can have only one argument to specify which rule to verify"
fi