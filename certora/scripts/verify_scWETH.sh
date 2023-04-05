#!/bin/bash
cd ../..
if [ "$#" -eq 0 ]
then 
  certoraRun  certora/harness/scWETH.sol \
              lib/solmate/src/tokens/WETH.sol \
              certora/mocks/AavePool.sol \
              certora/mocks/AToken.sol \
              certora/mocks/VariableDebtToken.sol \
              certora/mocks/WstETH.sol \
              certora/mocks/StETH.sol \
              certora/mocks/CurvePool.sol \
              certora/mocks/AggregatorV3.sol \
              certora/mocks/BalancerVault.sol \
    --link scWETH:asset=WETH \
    --link scWETH:aavePool=AavePool \
    --link scWETH:aToken=AToken \
    --link scWETH:variableDebtToken=VariableDebtToken \
    --link scWETH:weth=WETH \
    --link scWETH:wstETH=WstETH \
    --link scWETH:stEth=StETH \
    --link scWETH:curvePool=CurvePool \
    --link scWETH:stEThToEthPriceFeed=AggregatorV3 \
    --link scWETH:balancerVault=BalancerVault \
    --link WstETH:stETH=StETH \
    --link AavePool:aToken=AToken \
    --link AavePool:variableDebtToken=VariableDebtToken \
    --verify scWETH:certora/specs/scWETH.spec \
    --optimistic_loop \
    --smt_timeout 3600 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --settings -optimisticFallback=true,-smt_nonLinearArithmetic=true,-t=3600,-prettifyCEX=none,-multipleCEX=none \
    --msg "verifying scWETH"
elif [ "$#" -eq 1 ]
then
  certoraRun  certora/harness/scWETH.sol \
              lib/solmate/src/tokens/WETH.sol \
              certora/mocks/AavePool.sol \
              certora/mocks/AToken.sol \
              certora/mocks/VariableDebtToken.sol \
              certora/mocks/WstETH.sol \
              certora/mocks/StETH.sol \
              certora/mocks/CurvePool.sol \
              certora/mocks/AggregatorV3.sol \
              certora/mocks/BalancerVault.sol \
    --link scWETH:asset=WETH \
    --link scWETH:aavePool=AavePool \
    --link scWETH:aToken=AToken \
    --link scWETH:variableDebtToken=VariableDebtToken \
    --link scWETH:weth=WETH \
    --link scWETH:wstETH=WstETH \
    --link scWETH:stEth=StETH \
    --link scWETH:curvePool=CurvePool \
    --link scWETH:stEThToEthPriceFeed=AggregatorV3 \
    --link scWETH:balancerVault=BalancerVault \
    --link WstETH:stETH=StETH \
    --link AavePool:aToken=AToken \
    --link AavePool:variableDebtToken=VariableDebtToken \
    --verify scWETH:certora/specs/scWETH.spec \
    --optimistic_loop \
    --smt_timeout 3600 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --settings -optimisticFallback=true,-smt_nonLinearArithmetic=true,-t=3600,-prettifyCEX=none,-multipleCEX=none \
    --rule "$1" \
    --msg "verifying rule $1 for scWETH"
else
  echo "You can have only one argument to specify which rule to verify"
fi