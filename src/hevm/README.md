# Formal Verification of scWETHv2 Properties using hevm (Experimental)

This folder contains formal verification of scWETHv2 properties using the [hevm symbolic execution tool]([https://github.com/ethereum/hevm/releases/tag/release/0.51.0]).

The hevm tool does not support all features used in scWETHv2 and thus some adjustments were necessary:

* `scErrors.sol` needed to be removed from the folder `out`;
* hevm does not support cheatcodes yet;
* `scWETHv2.sol` and `scWETHv2props.sol` needed to be adjusted on the `weth` state variable. For some reason, hevm does not support this constructor call `constructor(ConstructorParams memory params)
        sc4626(params.admin, params.keeper, ERC20(params.weth), "Sandclock WETH Vault v2", "scWETHv2")`, in particular this type cast `ERC20(params.weth)`.

Running hevm on `scWETHv2props.sol` results in:

```
hevm test
Running 18 tests for src/hevm/scWETHv2props.sol:scWETHv2Props
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_integrity_of_setStEThToEthPriceFeed(address)
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_previewMintRoundingDirection(uint256)
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_setTreasury_reverts_if_address_is_zero()
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_converToShares_rounds_down_towards_0(uint256)
Exploring contract
Simplifying expression
Explored contract (2 branches)
Checking for reachability of 2 potential property violation(s)
[PASS] prove_convertToShares_gte_previewDeposit(uint256)
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_integrity_of_setTreasury(address)
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_invest_performanceFee()
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_revert_of_setStEThToEthPriceFeed()
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_convertToAssets_rounds_down_towards_0(uint256)
Exploring contract
Simplifying expression
Explored contract (2 branches)
Checking for reachability of 2 potential property violation(s)
[PASS] prove_convertRoundTrip2(uint256)
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_receiveFlashLoan_InvalidFlashLoanCaller()
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_integrity_of_setMinimumFloatAmount(uint256)
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_integrity_of_setSlippageTolerance(uint256)
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_maxDeposit_returns_correct_value(address)
Exploring contract
Simplifying expression
Explored contract (1 branches)
Checking for reachability of 1 potential property violation(s)
[PASS] prove_convertToSharesRoundingDirection()
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_reverts_setSlippageTolerance(uint256)
Exploring contract
Simplifying expression
Explored contract (3 branches)
Checking for reachability of 3 potential property violation(s)
[PASS] prove_maxMint_returns_correct_value(address)
Exploring contract
Simplifying expression
Explored contract (4 branches)
Checking for reachability of 4 potential property violation(s)
[PASS] prove_previewWithdrawRoundingDirection(uint256)
```
