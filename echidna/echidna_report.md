## Running echidna on-chain fuzzing for scUSDC & scWETH

Running crytic [pre-built](https://github.com/crytic/properties/tree/main/contracts/ERC4626) erc4626 tests with on-chain fuzzing on commit `b7f942f3182716107323f2c1039992104cf3186b` (n=100,000).
- harness ([scUSDC](https://github.com/lindy-labs/sandclock-contracts/blob/echidna/test/CryticTest.sol#L26), [scWETH](https://github.com/lindy-labs/sandclock-contracts/blob/echidna/test/CryticTest.sol#L77))
- coverage files ([scUSDC](https://github.com/lindy-labs/sandclock-contracts/blob/echidna/echidna/corpus/covered.1682534671.html), [scWETH](https://github.com/lindy-labs/sandclock-contracts/blob/echidna/echidna/corpus/covered.1682537438.html))

```
$ export ECHIDNA_RPC_URL=
$ export ECHIDNA_RPC_BLOCK=16771449
$ echidna . --contract CryticERC4626_scUSDC --config echidna.yaml

......

verify_previewWithdrawRoundingDirection(uint256):  passed! 🎉
verify_totalAssetsMustNotRevert():  passed! 🎉
mint(uint256,uint256):  passed! 🎉
verify_previewDepositIgnoresSender(uint256):  passed! 🎉
verify_withdrawProperties(uint256,uint256):  passed! 🎉
depositForSelfSimple(uint256):  passed! 🎉
verify_depositProperties(uint256,uint256):  passed! 🎉
verify_mintProperties(uint256,uint256):  passed! 🎉
verify_convertToSharesRoundingDirection():  passed! 🎉
verify_convertToSharesMustNotRevert(uint256):  passed! 🎉
verify_previewRedeemRoundingDirection():  passed! 🎉
verify_previewWithdrawIgnoresSender(uint256):  passed! 🎉
verify_withdrawRequiresTokenApproval(uint256,uint256,uint256):  passed! 🎉
verify_convertToAssetsMustNotRevert(uint256):  passed! 🎉
verify_previewMintRoundingDirection(uint256):  passed! 🎉
verify_maxRedeemMustNotRevert(address):  passed! 🎉
verify_redeemRequiresTokenApproval(uint256,uint256,uint256):  passed! 🎉
verify_mintRoundingDirection(uint256):  passed! 🎉
verify_redeemRoundingDirection():  passed! 🎉
verify_convertRoundTrip(uint256):  passed! 🎉
verify_maxDepositMustNotRevert(address):  passed! 🎉
verify_maxMintIgnoresSenderAssets(uint256):  passed! 🎉
verify_withdrawRoundingDirection(uint256):  passed! 🎉
recognizeLossProxy(uint256):  passed! 🎉
verify_previewDepositRoundingDirection():  passed! 🎉
verify_previewRedeemIgnoresSender(uint256):  passed! 🎉
verify_sharePriceInflationAttack(uint256,uint256): failed!💥
  Call sequence:
    verify_sharePriceInflationAttack(10089,34)

Event sequence: Panic(1): Using assert., Transfer(10089) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Approval(10089) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(1) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(1) from: 0xee35211c4d9126d520bbfeaf3cfee5fe7b86f221, Deposit(1, 1) from: 0xee35211c4d9126d520bbfeaf3cfee5fe7b86f221, Transfer(10088) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(10123) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Approval(115792089237316195423570985008687907853269984665640564039457584007913129639935) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, LogUint256(«Amount of alice's deposit:», 10123) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, Transfer(10123) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(1) from: 0xee35211c4d9126d520bbfeaf3cfee5fe7b86f221, Deposit(10123, 1) from: 0xee35211c4d9126d520bbfeaf3cfee5fe7b86f221, LogUint256(«Alice Shares:», 1) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, Transfer(1) from: 0xee35211c4d9126d520bbfeaf3cfee5fe7b86f221, Withdraw(10106, 1) from: 0xee35211c4d9126d520bbfeaf3cfee5fe7b86f221, Transfer(10106) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, LogUint256(«Amount of tokens alice withdrew:», 10106) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«Alice Loss:», 17) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«lossThreshold», 999000000000000000) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«minRedeemedAmountNorm», 10112) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, AssertGtFail(«Invalid: 10106<=10112 failed, reason: Share inflation attack possible, victim lost an amount over lossThreshold%») from: 0xa329c0648769a73afac7f9381e08fb43dbea72
verify_convertRoundTrip2(uint256):  passed! 🎉
verify_assetDecimalsLessThanVault():  passed! 🎉
verify_maxMintMustNotRevert(address):  passed! 🎉
withdraw(uint256,uint256,uint256):  passed! 🎉
verify_assetMustNotRevert():  passed! 🎉
redeemForSelfSimple(uint256):  passed! 🎉
verify_redeemViaApprovalProxy(uint256,uint256):  passed! 🎉
verify_maxDepositIgnoresSenderAssets(uint256):  passed! 🎉
redeem(uint256,uint256,uint256):  passed! 🎉
mintAsset(uint256,uint256):  passed! 🎉
verify_convertToAssetsRoundingDirection():  passed! 🎉
verify_maxWithdrawMustNotRevert(address):  passed! 🎉
verify_withdrawViaApprovalProxy(uint256,uint256):  passed! 🎉
recognizeProfitProxy(uint256):  passed! 🎉
verify_previewMintIgnoresSender(uint256,uint256):  passed! 🎉
deposit(uint256,uint256):  passed! 🎉
verify_redeemProperties(uint256,uint256):  passed! 🎉
verify_depositRoundingDirection():  passed! 🎉
AssertionFailed(..):  passed! 🎉
Unique instructions: 17535
Unique codehashes: 9
Corpus size: 38
Seed: 4472767603407369906
```

```
$ echidna . --contract CryticERC4626_scWETH --config echidna.yaml

....

verify_previewWithdrawRoundingDirection(uint256):  passed! 🎉
verify_totalAssetsMustNotRevert():  passed! 🎉
mint(uint256,uint256):  passed! 🎉
verify_previewDepositIgnoresSender(uint256):  passed! 🎉
verify_withdrawProperties(uint256,uint256):  passed! 🎉
depositForSelfSimple(uint256):  passed! 🎉
verify_depositProperties(uint256,uint256):  passed! 🎉
verify_mintProperties(uint256,uint256):  passed! 🎉
verify_convertToSharesRoundingDirection():  passed! 🎉
verify_convertToSharesMustNotRevert(uint256):  passed! 🎉
verify_previewRedeemRoundingDirection():  passed! 🎉
verify_previewWithdrawIgnoresSender(uint256):  passed! 🎉
verify_withdrawRequiresTokenApproval(uint256,uint256,uint256):  passed! 🎉
verify_convertToAssetsMustNotRevert(uint256):  passed! 🎉
verify_previewMintRoundingDirection(uint256):  passed! 🎉
verify_maxRedeemMustNotRevert(address):  passed! 🎉
verify_redeemRequiresTokenApproval(uint256,uint256,uint256):  passed! 🎉
verify_mintRoundingDirection(uint256):  passed! 🎉
verify_redeemRoundingDirection():  passed! 🎉
verify_convertRoundTrip(uint256):  passed! 🎉
verify_maxDepositMustNotRevert(address):  passed! 🎉
verify_maxMintIgnoresSenderAssets(uint256):  passed! 🎉
verify_withdrawRoundingDirection(uint256):  passed! 🎉
recognizeLossProxy(uint256):  passed! 🎉
verify_previewDepositRoundingDirection():  passed! 🎉
verify_previewRedeemIgnoresSender(uint256):  passed! 🎉
verify_sharePriceInflationAttack(uint256,uint256): failed!💥
  Call sequence:
    verify_sharePriceInflationAttack(10002,29)

Event sequence: Panic(1): Using assert., Transfer(10002) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Approval(10002) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(1) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, Deposit(1, 1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, Transfer(10001) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(10031) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Approval(115792089237316195423570985008687907853269984665640564039457584007913129639935)
from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, LogUint256(«Amount of alice's deposit:», 10031) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, Transfer(10031) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, Transfer(1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, Deposit(10031, 1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, LogUint256(«Alice Shares:», 1) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, Transfer(1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, Withdraw(10016, 1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, Transfer(10016) from: 0xb4c79dab8f259c7aee6e5b2aa729821864227e84, LogUint256(«Amount of tokens alice withdrew:», 10016) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«Alice Loss:», 15) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«lossThreshold», 999000000000000000) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«minRedeemedAmountNorm», 10020) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, AssertGtFail(«Invalid: 10016<=10020 failed, reason: Share inflation attack possible, victim lost an amount over lossThreshold%») from: 0xa329c0648769a73afac7f9381e08fb43dbea72
verify_convertRoundTrip2(uint256):  passed! 🎉
verify_assetDecimalsLessThanVault():  passed! 🎉
verify_maxMintMustNotRevert(address):  passed! 🎉
withdraw(uint256,uint256,uint256):  passed! 🎉
verify_assetMustNotRevert():  passed! 🎉
redeemForSelfSimple(uint256):  passed! 🎉
verify_redeemViaApprovalProxy(uint256,uint256):  passed! 🎉
verify_maxDepositIgnoresSenderAssets(uint256):  passed! 🎉
redeem(uint256,uint256,uint256):  passed! 🎉
mintAsset(uint256,uint256):  passed! 🎉
verify_convertToAssetsRoundingDirection():  passed! 🎉
verify_maxWithdrawMustNotRevert(address):  passed! 🎉
verify_withdrawViaApprovalProxy(uint256,uint256): failed!💥
  Call sequence:
    depositForSelfSimple(1)
    verify_withdrawViaApprovalProxy(0,1)

Event sequence: Panic(1): Using assert., LogUint256(«Tokens to use in withdraw:», 1) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, Approval(1) from: 0x62d69f6867a0a084c6d313943dc22023bc263691, LogUint256(«asset.balanceOf(vault) (before withdraw)», 0) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, LogUint256(«vault.balanceOf(vault) (before withdraw)», 1) from: 0xa329c0648769a73afac7f9381e08fb43dbea72, error Revert PleaseUseRedeemMethod (), error Revert PleaseUseRedeemMethod (), AssertFail(«vault.withdraw() reverted during withdraw via approval») from: 0xa329c0648769a73afac7f9381e08fb43dbea72
recognizeProfitProxy(uint256):  passed! 🎉
verify_previewMintIgnoresSender(uint256,uint256):  passed! 🎉
deposit(uint256,uint256):  passed! 🎉
verify_redeemProperties(uint256,uint256):  passed! 🎉
verify_depositRoundingDirection():  passed! 🎉
AssertionFailed(..):  passed! 🎉
Unique instructions: 17619
Unique codehashes: 9
Corpus size: 25
Seed: 7157052948872830944
```
