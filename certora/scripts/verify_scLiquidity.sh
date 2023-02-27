#!/bin/bash
cd ../..
if [ "$#" -eq 0 ]
then 
  certoraRun  src/liquity/scLiquity.sol \
              test/mock/MockStabilityPool.sol \
              test/mock/MockPriceFeed.sol \
              test/mock/MockLiquityPriceFeed.sol \
              certora/mocks/MockLUSD.sol \
              certora/mocks/MockLQTY.sol \
	  --link  MockStabilityPool:lusd=MockLUSD \
            MockStabilityPool:pricefeed=MockLiquityPriceFeed \
            scLiquity:asset=MockLUSD \
            scLiquity:stabilityPool=MockStabilityPool \
            scLiquity:lusd2eth=MockPriceFeed \
            scLiquity:lqty=MockLQTY \
    --verify scLiquity:certora/specs/scLiquity.spec \
    --optimistic_loop \
    --loop_iter 3 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --settings -optimisticFallback=true \
    --msg "verifying scLiquity"
elif [ "$#" -eq 1 ]
then
  certoraRun  src/liquity/scLiquity.sol \
              test/mock/MockStabilityPool.sol \
              test/mock/MockPriceFeed.sol \
              test/mock/MockLiquityPriceFeed.sol \
              certora/mocks/MockLUSD.sol \
              certora/mocks/MockLQTY.sol \
	  --link MockStabilityPool:lusd=MockLUSD \
            MockStabilityPool:pricefeed=MockLiquityPriceFeed \
            scLiquity:asset=MockLUSD \
            scLiquity:stabilityPool=MockStabilityPool \
            scLiquity:lusd2eth=MockPriceFeed \
            scLiquity:lqty=MockLQTY \
    --verify scLiquity:certora/specs/scLiquity.spec \
    --optimistic_loop \
    --loop_iter 3 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --settings -optimisticFallback=true \
    --rule "$1" \
    --msg "verifying rule $1 for scLiquity"
else
  echo "You can have only one argument to specify which rule to verify"
fi