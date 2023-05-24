# Formal Verification of scWETHv2 Properties using hevm (Experimental)

This folder contains formal verification of scWETHv2 properties using the [hevm symbolic execution tool]([https://github.com/ethereum/hevm/releases/tag/release/0.51.0]).

The hevm tool does not support all features used in scWETHv2 and thus some adjustments were necessary:

* `scErrors.sol` needed to be removed as well as all its references in `scWETHv2.sol`, `OracleLib.sol`, `LendingMarketManager.sol`, and `scWETH2Helper.sol`;
* `scUSDC.sol` needed to be removed from the `forge build` compilation because the created json for an empty file (content is solely based on comments) cannot be processed by hevm (issue reported in its repo);
* Cheatcodes are not supported yet;
* `scWETHv2.sol` and `scWETHv2props.sol` needed to be adjusted on the `weth` state variable. For some reason, hevm does not support this constructor call `constructor(ConstructorParams memory params)
        sc4626(params.admin, params.keeper, ERC20(params.weth), "Sandclock WETH Vault v2", "scWETHv2")`, in particular this type cast `ERC20(params.weth)`.

Running hevm on `scWETHv2props.sol` results in:

```
% time hevm test
Running 25 tests for src/hevm/scWETHv2props.sol:scWETHv2Props
Exploring contract
Simplifying expression
Explored contract (15208 branches)
Checking for reachability of 15208 potential property violation(s)
[PASS] prove_integrity_of_redeem(uint256,address,address) 🎉
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_integrity_of_setStEThToEthPriceFeed(address) 🎉
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_previewMintRoundingDirection(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_setTreasury_reverts_if_address_is_zero() 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_converToShares_rounds_down_towards_0(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (2 branches)
Checking for reachability of 2 potential property violation(s)
[PASS] prove_convertToShares_gte_previewDeposit(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (290 branches)
Checking for reachability of 290 potential property violation(s)
[PASS] prove_previewRedeem_lte_redeem(uint256,address,address) 🎉
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_integrity_of_setTreasury(address) 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_invest_performanceFee()
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_revert_of_setStEThToEthPriceFeed() 🎉
Exploring contract
Simplifying expression
Explored contract (119 branches)
Checking for reachability of 119 potential property violation(s)
[PASS] prove_deposit(uint256,address) 🎉
Exploring contract
Simplifying expression
Explored contract (41 branches)
Checking for reachability of 41 potential property violation(s)
[PASS] prove_redeem_reverts_if_not_enough_shares(uint256,address,address) 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_convertToAssets_rounds_down_towards_0(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (2 branches)
Checking for reachability of 2 potential property violation(s)
[PASS] prove_convertRoundTrip2(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (109 branches)
Checking for reachability of 109 potential property violation(s)
[PASS] prove_integrity_of_mint(uint256,address) 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_receiveFlashLoan_InvalidFlashLoanCaller() 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_integrity_of_setMinimumFloatAmount(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_integrity_of_setSlippageTolerance(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_maxDeposit_returns_correct_value(address) 🎉
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_convertToSharesRoundingDirection() 🎉
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_reverts_setSlippageTolerance(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_withdraw_revert(uint256,address,address) 🎉
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_maxMint_returns_correct_value(address) 🎉
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_previewWithdrawRoundingDirection(uint256) 🎉
Exploring contract
Simplifying expression
Explored contract (2 branches)
Checking for reachability of 2 potential property violation(s)
[PASS] prove_convertToAssets_lte_previewMint(uint256) 🎉

hevm test  2399,44s user 87,19s system 797% cpu 5:11,73 total
```
