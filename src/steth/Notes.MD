## Maybe Later

1. Add float if makes sense for small withdrawals
2. Use 0x in the depositToStrategy, because in case of an event
   where price of stETH falls very much (which happened few months ago) it will
   be better to swap from other protocols instead of just staking to lido
3. share price inflation attack\
4. deposit eth
5. chainlink backup

Notes:

totalAssets = totalCollateral - totalDebt
leverage = totalDebt / totalAssets

hence => as totalCollateral increases due to interest, leverage will decrease
proof => x/(1-x) > y/(1-y) if x < y

### I dont know why but we are losing 0.17% of the deposit directly after each deposit
