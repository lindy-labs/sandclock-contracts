#!/bin/bash
if [ "$#" -eq 0 ]
then 
  certoraRun  src/liquity/scLiquity.sol:scLiquity \
              lib/solmate/src/test/utils/mocks/MockERC20.sol \
              test/mock/MockStabilityPool.sol:MockStabilityPool \
              test/mock/MockPriceFeed.sol:MockPriceFeed \
              test/mock/MockLiquityPriceFeed.sol:MockLiquityPriceFeed \
              test/mock/MockExchange.sol:MockExchange \
              test/mock/Mock0x.sol:Mock0x \
              certora/mocks/MockLUSD.sol:MockLUSD \
              certora/mocks/MockLQTY.sol:MockLQTY \
	  --link  MockStabilityPool:lusd=MockERC20 \
            MockStabilityPool:pricefeed=MockLiquityPriceFeed \
            scLiquity:asset=MockLUSD \
            scLiquity:stabilityPool=MockStabilityPool \
            scLiquity:lusd2eth=MockPriceFeed \
            scLiquity:lqty=MockLQTY \
            scLiquity:xrouter=Mock0x \
    --verify scLiquity:certora/specs/scLiquity.spec \
    --optimistic_loop \
    --loop_iter 1 \
    --packages  solmate=lib/solmate/src/ \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --msg "verifying Vault"
elif [ "$#" -eq 1 ]
then
  certoraRun src/liquity/scLiquity.sol:scLiquity \
              lib/solmate/src/test/utils/mocks/MockERC20.sol \
              test/mock/MockStabilityPool.sol:MockStabilityPool \
              test/mock/MockPriceFeed.sol:MockPriceFeed \
              test/mock/MockLiquityPriceFeed.sol:MockLiquityPriceFeed \
              test/mock/MockExchange.sol:MockExchange \
              test/mock/Mock0x.sol:Mock0x \
              certora/mocks/MockLUSD.sol:MockLUSD \
              certora/mocks/MockLQTY.sol:MockLQTY \
	  --link MockStabilityPool:lusd=MockERC20 \
            MockStabilityPool:pricefeed=MockLiquityPriceFeed \
            scLiquity:asset=MockLUSD \
            scLiquity:stabilityPool=MockStabilityPool \
            scLiquity:lusd2eth=MockPriceFeed \
            scLiquity:lqty=MockLQTY \
            scLiquity:xrouter=Mock0x \
    --verify scLiquity:certora/specs/scLiquity.spec \
    --optimistic_loop \
    --loop_iter 1 \
    --packages  solmate=lib/solmate/src/ \
                openzeppelin-contracts=lib/openzeppelin-contracts/contracts \
    --rule "$1" \
    --msg "verifying rule $1 for Vault"
else
  echo "You can have only one argument to specify which rule to verify"
fi