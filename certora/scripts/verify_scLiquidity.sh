#!/bin/bash
cd ../..
if [ "$#" -eq 0 ]
then 
  certoraRun  src/liquity/scLiquity.sol \
              test/mock/MockStabilityPool.sol \
              test/mock/MockPriceFeed.sol \
              test/mock/MockLiquityPriceFeed.sol \
              test/mock/Mock0x.sol \
              certora/mocks/MockLUSD.sol \
              certora/mocks/MockLQTY.sol \
	  --link  MockStabilityPool:lusd=MockLUSD \
            MockStabilityPool:pricefeed=MockLiquityPriceFeed \
            scLiquity:asset=MockLUSD \
            scLiquity:stabilityPool=MockStabilityPool \
            scLiquity:lusd2eth=MockPriceFeed \
            scLiquity:lqty=MockLQTY \
            scLiquity:xrouter=Mock0x \
    --verify scLiquity:certora/specs/scLiquity.spec \
    --optimistic_loop \
    --loop_iter 3 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --msg "verifying Vault"
elif [ "$#" -eq 1 ]
then
  certoraRun  src/liquity/scLiquity.sol \
              test/mock/MockStabilityPool.sol \
              test/mock/MockPriceFeed.sol \
              test/mock/MockLiquityPriceFeed.sol \
              test/mock/Mock0x.sol \
              certora/mocks/MockLUSD.sol \
              certora/mocks/MockLQTY.sol \
	  --link MockStabilityPool:lusd=MockLUSD \
            MockStabilityPool:pricefeed=MockLiquityPriceFeed \
            scLiquity:asset=MockLUSD \
            scLiquity:stabilityPool=MockStabilityPool \
            scLiquity:lusd2eth=MockPriceFeed \
            scLiquity:lqty=MockLQTY \
            scLiquity:xrouter=Mock0x \
    --verify scLiquity:certora/specs/scLiquity.spec \
    --optimistic_loop \
    --loop_iter 3 \
    --packages  solmate=lib/solmate/src \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --rule "$1" \
    --msg "verifying rule $1 for Vault"
else
  echo "You can have only one argument to specify which rule to verify"
fi