![Lindy Labs](assets/ll-white.png)

This audit was prepared by Lindy Labs and represents a snapshot of the repository taken on April 10 2023.

# Formal Verification of contracts
 
## Summary

The Certora Prover has partially proven the implementation of the scUSDC contract is correct with respect to formal specifications written by the security team of Lindy Labs, but Certora timed out on several rules. The common characteristics of the rules are that they verify functions that call the `receiveFlashLoan` function. The `receiveFlashLoan` is the most complicated function in the contract because it interacts 7 external contracts.

A manual audit of these contracts was also conducted.

## List of Issues Discovered

No issues were uncovered.

# Overview of the verification

## Description of the contracts

Both scUSDC and scWETH contracts inherit the properties of ERC-4626, a standard that simplifies and harmonizes the technical requirements of yield-bearing vaults. This standard provides a uniform interface for yield-bearing vaults that are represented by tokenized shares of an ERC-20 token. Furthermore, ERC-4626 has an elective add-on for vaults that utilize ERC-20 tokens, which includes fundamental functionalities such as token deposit, withdrawal, and balance inquiry.


## Assumptions and Simplifications

The following assumptions were made during the verification process:

- Loops are unrolled by max 1 time. Violations that require a loop to execute more than 3 times will not be detected.
- When verifying contracts that make external calls, there is an assumption these calls can have arbitrary side effects outside of the contracts, but they do not affect the state of the contract being verified. This means that some reentrancy bugs may not be caught. However, stactic analysis and previous audits should have already covered all possible reentrancy attacks.

## Verification Conditions

### Notation

✔️ indicates the rule is formally verified on the latest reviewed commit. Footnotes describe any simplifications or assumptions used while verifying the rules (beyond the general assumptions listed above).

In this document, verification conditions are either shown as logical formulas or Hoare triples of the form {p} C {q}. A verification condition given by a logical formula denotes an invariant that holds if every reachable state satisfies the condition.

Hoare triples of the form {p} C {q} holds if any non-reverting execution of program C that starts in a state satsifying the precondition p ends in a state satisfying the postcondition q. The notation {p} C@withrevert {q} is similar but applies to both reverting and non-reverting executions. Preconditions and postconditions are similar to the Solidity require and statements.

Formulas relate the results of method calls. In most cases, these methods are getters defined in the contracts, but in some cases they are getters we have added to our harness or definitions provided in the rules file. Undefined variables in the formulas are treated as arbitrary: the rule is checked for every possible value of the variables.

## Properties

### scUSDC

#### 1. function converToShares returns the same value ✔️

```
    { e.msg.sender != e2.msg.sender }

    { convertToShares(e, assets) == convertToShares(e2, assets) }
```

#### 2. function convertToShares returns at least the same amount of shares than function previewDeposit ✔️

```
    convertToShares(e, assets) >= previewDeposit(assets)    
```

#### 3. function converToShares rounds down shares towards zero - Certora time out

```
    { totalSupply() != 0 }

        totalSupply = totalSupply()
        totalAssets = totalAssets()
        shares_ = convertToShares(e, assets)

    { (assets * totalSupply) / totalAssets == shares_ }

```

#### 4. function convertToShares maintains share prices - Certora time out

```
    { 
        totalSupply_equals_totalShares
        _shares = convertToShares(e, assets) 
        e1.msg.value == 0
    }

        f(e1, args)
        shares_ = convertToShares(e2, assets)

    { _shares == shares_ }
```

#### 5. share price maintained after mint - Certora timed out

```
    { 
        e.msg.sender != currentContract
        e.msg.sender != stabilityPool()
        receiver != currentContract
        _totalAssets == 0 <=> totalSupply() == 0
        priceFeed.latestAnswer() == 0
        totalAssets() + assets <= asset.totalSupply()
    }
    
        assets = mint(e, shares, receiver)

    { assets == previewMint(shares) }
```

#### 6. function convertToAssets returns the same value for a given parameter regardless of the caller ✔️

```
    { e2.msg.sender != e.msg.sender }    
    { convertToAssets(e, shares) == convertToAssets(e2, shares) }
```

#### 7. function convertToAssets returns at most the same amount of assets than function previewMint ✔️

```
    convertToAssets(e, shares) <= previewMint(shares)
```

#### 8. function convertToAssets rounds assets towards zero - Certora time out

```
    { totalSupply() != 0 }
    
        totalAssets = totalAssets()
        totalSupply = totalSupply()
        assets = convertToAssets(e, shares)
    
    { (shares * totalAssets) / totalSupply == assets }
```

#### 9. function maxDeposit returns the maximum expected value of a deposit ✔️

```
    maxDeposit(receiver) == 2^256 - 1
```

#### 10. function maxMint returns the maximum expected value of a mint ✔️

```
    maxMint(receiver) == 2^256 - 1
```

#### 11. function previewDeposit returns at most the same amount of assets than function deposit ✔️

```
    previewDeposit(assets) <= deposit(e, assets, receiver)
```


#### 12. function previewMint returns at least the same amount of shares than function mint ✔️

```
    previewMint(shares) >= mint(e, shares, receiver)
```

#### 13. function previewWithdraw returns at least the same amount of assets than function withdraw - Certora time out

```
    previewWithdraw(assets) >= withdraw(e, assets, receiver, owner)
```

#### 14. function previewRedeem returns at most the same amount of shares than function redeem - Certora time out

```
    previewRedeem(shares) <= redeem(e, shares, receiver, owner)
```

#### 15. function deposit mints exactly shares Vault shares to receiver by depositing exactly assets of underlying tokens ✔️

```
    { 
        e.msg.sender != currentContract
        receiver != currentContract
        _totalAssets + assets <= asset.totalSupply()
        _receiverShares + shares <= totalSupply() 
    }
    
        _userAssets = asset.balanceOf(e.msg.sender)
        _totalAssets = totalAssets()
        _receiverShares = balanceOf(receiver)

        shares = deposit(e, assets, receiver)

        userAssets_ = asset.balanceOf(e.msg.sender)
        totalAssets_ = totalAssets()
        receiverShares_ = balanceOf(receiver)

    { 
        _userAssets - assets == userAssets_
        _totalAssets + assets == totalAssets_
        _receiverShares + shares == receiverShares_ 
    }
```


#### 16. function deposit must revert if all of assets cannot be deposited ✔️

```
    { userAssets < assets }

        userAssets = asset.balanceOf(e.msg.sender)
        deposit@withrevert(e, assets, receiver)

    { lastReverted }
```

#### 17. function mint mints exactly shares Vault shares to receiver ✔️

```
    { 
        e.msg.sender != currentContract
        receiver != currentContract
        _receiverShares + shares <= totalSupply()
        _totalAssets + assets <= asset.totalSupply() 
    }

        _userAssets = asset.balanceOf(e.msg.sender)
        _totalAssets = totalAssets()
        _receiverShares = balanceOf(receiver)

        assets = mint(e, shares, receiver)

        userAssets_ = asset.balanceOf(e.msg.sender)
        totalAssets_ = totalAssets()
        receiverShares_ = balanceOf(receiver)

    { 
        _userAssets - assets == userAssets_
        _totalAssets + assets == totalAssets_
        _receiverShares + shares == receiverShares_ 
    }
```


#### 18. function mint reverts if the minter has not enough assets ✔️
```
    { asset.balanceOf(e.msg.sender) < previewMint(shares) }

        mint@withrevert(e, shares, receiver)

    { lastReverted }
```

#### 19. function withdraw must burn shares from owner and sends exactly assets of underlying tokens to receiver - Certora times out

```
    {
        e.msg.sender != currentContract
        receiver != currentContract
        e.msg.sender != owner
        owner != currentContract
        owner != receiver
        _receiverAssets + assets <= asset.totalSupply()
    }

        _receiverAssets = asset.balanceOf(receiver)
        _ownerShares = balanceOf(owner)
        _senderAllowance = allowance(owner, e.msg.sender)
        shares = withdraw(e, assets, receiver, owner)
        receiverAssets_ = asset.balanceOf(receiver)
        ownerShares_ = balanceOf(owner)
        senderAllowance_ = allowance(owner, e.msg.sender)

    {
        _receiverAssets + assets == receiverAssets_
        _ownerShares - shares == ownerShares_
        e.msg.sender != owner => 
        _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
        || _senderAllowance - shares == senderAllowance_
    }
```

#### 20. function withdraw reverts unconditionally - Certora time out

```
    {}

        withdraw@withrevert(e, assets, receiver, owner)

    { lastReverted }
```

#### 21. function redeem must burn exactly shares from owner and sends assets of underlying tokens to receiver - Certora time out

```
    { 
        e.msg.sender != currentContract
        receiver != currentContract
        _receiverAssets + assets <= asset.totalSupply() 
    }

        _receiverAssets = asset.balanceOf(receiver)
        _totalAssets = totalAssets()
        _ownerShares = balanceOf(owner)
        _senderAllowance = allowance(owner, e.msg.sender)

        assets = redeem(e, shares, receiver, owner)

        totalAssets_ = totalAssets()
        receiverAssets_ = asset.balanceOf(receiver)
        ownerShares_ = balanceOf(owner)
        senderAllowance_ = allowance(owner, e.msg.sender)

    { 
        _totalAssets - assets == totalAssets_
        _receiverAssets + assets == receiverAssets_
        _ownerShares - shares == ownerShares_
        e.msg.sender != owner => 
            _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
            ||
             _senderAllowance - shares == senderAllowance_ 
    }
```

#### 22. function redeem reverts if there is not enough shares - Certora time out

```
    { 
        balanceOf(owner) < shares 
        || 
        e.msg.sender != owner && allowance(owner, e.msg.sender) < shares 
    }

        redeem@withrevert(e, shares, receiver, owner)

    { lastReverted }
```

#### 23. function changeLeverage updates the state variable flashloanLtv using newFlashloanLtv - Certora time out

```
    { }
        
        changeLeverage(e, newFlashloanLtv)

    { targetLtv() == newFlashloanLtv }
```

#### 24. function changeLeverage reverts if newFlashloanLtv exceeds maxLtv - Certora time out

```
    { newFlashloanLtv > getMaxLtv() }
        
        changeLeverage@withrevert(e, newFlashloanLtv)

    { lastReverted }
```

#### 25. function receiveFlashLoan reverts the caller is not balancerVault  - Certora time out

```
    { e.msg.sender != balancerVault() }
        
        receiveFlashLoan@withrevert(e, args)

    { lastReverted }
```


#### 26. function setPerformanceFee updates the state variable performanceFee using newPerformanceFee ✔️

```
    {}
        
        setPerformanceFee(e, newPerformanceFee)

    { performanceFee() == newPerformanceFee }
```

#### 27. function setFloatPercentage updates the state variable performanceFee with the value provided by the parameter newPerformanceFee ✔️

```
    {}
    
        setFloatPercentage(e, newFloatPercentage)

    { floatPercentage() == newFloatPercentage }
```

#### 28. function setTreasury updates the state variable treasury with the value provided by the parameter newTreasury ✔️

```
    {}
        
        setTreasury(e, newTreasury)

    { treasury() == newTreasury }
```

#### 29. function setPerformanceFee reverts if the value of the parameter newPerformanceFee is greater than 10^18 ✔️

```
    { newPerformanceFee > 10^18 }
    
        setPerformanceFee@withrevert(e, newPerformanceFee)

    { lastReverted }
```

#### 30. function setFloatPercentage reverts if the value of the parameter newFloatPercentage is greater than 10^18 ✔️

```
    { newFloatPercentage > 10^18 }
    
        setFloatPercentage@withrevert(e, newFloatPercentage)

    { lastReverted }
```

#### 31. function setTreasury reverts if address(0) ✔️

```
    {}
    
        setTreasury@withrevert(e, 0)

    { lastReverted }
```


#### 32. function setSlippageTolerance should update slippageTolerance if _slippageTolerance <= ONE ✔️
        
```
    { _slippageTolerance <= ONE() }

        setSlippageTolerance(e, _slippageTolerance)
    
    { slippageTolerance() == _slippageTolerance }
```

#### 33. function setSlippageTolerance reverts if _slippageTolerance > ONE ✔️
        
```
    { _slippageTolerance > ONE() }

        setSlippageTolerance@withrevert(e, _slippageTolerance);
    
    { lastReverted}
```

#### 34. function applyNewTargetLtv updates the state variable `slippageTolerance` with the value provided by `_newSlippageTolerance` and rebalances the Vault - Certora time out
        
```
    { _newTargetLtv <= getMaxLtv() }

        applyNewTargetLtv(e, _newTargetLtv);
    
    { targetLtv() == _newTargetLtv }
```

#### 35. function applyNewTargetLtv reverts if `_newTargetLtv` is greater than the maximum `LTV` - Certora time out
        
```
    { _newTargetLtv > getMaxLtv() }

    applyNewTargetLtv@withrevert(e, _newTargetLtv);
    
    { lastReverted }
```

#### 36. function rebalance should rebalance the vault's positions - Certora time out
        
```
    {}

        uint256 _collateral = getCollateral();
        uint256 _invested = getInvested();
        uint256 _usdcBalance = getUsdcBalance();
        rebalance(e);

    {
        getCollateral() >= _collateral
        _invested >= getInvested()
        _usdcBalance >= getUsdcBalance()
    }
```

#### 37. function rebalance should respect target Ltv percentage - Certora time out
        
```
    { getLtv() == 0 }

        rebalance(e)

    {
        targetLtv() == 0 => getLtv() == targetLtv()
        targetLtv() != 0 => percentDelta(getLtv(), targetLtv()) <= (1/100)^18
    }
```

#### 38. function exitAllPositions should perform an emergency exit to release collateral if the vault is underwater - Certora time out
        
```
    {}

        uint256 _totalBefore = totalAssets();
        exitAllPositions(e);

    {
        getCollateral() == 0;
        getDebt() == 0;
        percentDelta(getUsdcBalance(), _totalBefore) <= (1/100)^18
    }
```

#### 39. function exitAllPositions should revert if the invested value is greater then or equal to the debt - Certora time out
        
```
    { getInvested() >= getDebt() }

        exitAllPositions@withrevert(e)

    { lastReverted }
```

### scWETH

#### 1. function converToShares returns the same value ✔️

```
    { e.msg.sender != e2.msg.sender }

    { convertToShares(e, assets) == convertToShares(e2, assets) }
```

#### 2. function convertToShares returns at least the same amount of shares than function previewDeposit ✔️

```
    convertToShares(e, assets) >= previewDeposit(assets)    
```

#### 3. function converToShares rounds down shares towards zero ✔️

```
    { totalSupply() != 0 }

        totalSupply = totalSupply()
        totalAssets = totalAssets()
        shares_ = convertToShares(e, assets)

    { (assets * totalSupply) / totalAssets == shares_ }

```

#### 4. function convertToShares maintains share prices - Certora time out

```
    { 
        totalSupply_equals_totalShares
        _shares = convertToShares(e, assets) 
        e1.msg.value == 0
    }

        f(e1, args)
        shares_ = convertToShares(e2, assets)

    { _shares == shares_ }
```

#### 5. share price maintained after mint - Certora timed out

```
    { 
        e.msg.sender != currentContract
        e.msg.sender != stabilityPool()
        receiver != currentContract
        _totalAssets == 0 <=> totalSupply() == 0
        priceFeed.latestAnswer() == 0
        totalAssets() + assets <= asset.totalSupply()
    }
    
        assets = mint(e, shares, receiver)

    { assets == previewMint(shares) }
```

#### 6. function convertToAssets returns the same value for a given parameter regardless of the caller ✔️

```
    { e2.msg.sender != e.msg.sender }    
    { convertToAssets(e, shares) == convertToAssets(e2, shares) }
```

#### 7. function convertToAssets returns at most the same amount of assets than function previewMint ✔️

```
    convertToAssets(e, shares) <= previewMint(shares)
```

#### 8. function convertToAssets rounds assets towards zero ✔️

```
    { totalSupply() != 0 }
    
        totalAssets = totalAssets()
        totalSupply = totalSupply()
        assets = convertToAssets(e, shares)
    
    { (shares * totalAssets) / totalSupply == assets }
```

#### 9. function maxDeposit returns the maximum expected value of a deposit ✔️

```
    maxDeposit(receiver) == 2^256 - 1
```

#### 10. function maxMint returns the maximum expected value of a mint ✔️

```
    maxMint(receiver) == 2^256 - 1
```

#### 11. function previewDeposit returns at most the same amount of assets than function deposit ✔️

```
    previewDeposit(assets) <= deposit(e, assets, receiver)
```


#### 12. function previewMint returns at least the same amount of shares than function mint ✔️

```
    previewMint(shares) >= mint(e, shares, receiver)
```

#### 13. function previewRedeem returns at most the same amount of shares than function redeem - Certora time out

```
    previewRedeem(shares) <= redeem(e, shares, receiver, owner)
```

#### 14. function deposit mints exactly shares Vault shares to receiver by depositing exactly assets of underlying tokens ✔️

```
    { 
        e.msg.sender != currentContract
        receiver != currentContract
        _totalAssets + assets <= asset.totalSupply()
        _receiverShares + shares <= totalSupply() 
    }
    
        _userAssets = asset.balanceOf(e.msg.sender)
        _totalAssets = totalAssets()
        _receiverShares = balanceOf(receiver)

        shares = deposit(e, assets, receiver)

        userAssets_ = asset.balanceOf(e.msg.sender)
        totalAssets_ = totalAssets()
        receiverShares_ = balanceOf(receiver)

    { 
        _userAssets - assets == userAssets_
        _totalAssets + assets == totalAssets_
        _receiverShares + shares == receiverShares_ 
    }
```


#### 15. function deposit must revert if all of assets cannot be deposited ✔️

```
    { userAssets < assets }

        userAssets = asset.balanceOf(e.msg.sender)
        deposit@withrevert(e, assets, receiver)

    { lastReverted }
```

#### 16. function mint mints exactly shares Vault shares to receiver ✔️

```
    { 
        e.msg.sender != currentContract
        receiver != currentContract
        _receiverShares + shares <= totalSupply()
        _totalAssets + assets <= asset.totalSupply() 
    }

        _userAssets = asset.balanceOf(e.msg.sender)
        _totalAssets = totalAssets()
        _receiverShares = balanceOf(receiver)

        assets = mint(e, shares, receiver)

        userAssets_ = asset.balanceOf(e.msg.sender)
        totalAssets_ = totalAssets()
        receiverShares_ = balanceOf(receiver)

    { 
        _userAssets - assets == userAssets_
        _totalAssets + assets == totalAssets_
        _receiverShares + shares == receiverShares_ 
    }
```


#### 17. function mint reverts if the minter has not enough assets ✔️
```
    { asset.balanceOf(e.msg.sender) < previewMint(shares) }

        mint@withrevert(e, shares, receiver)

    { lastReverted }
```


#### 18. function withdraw reverts unconditionally ✔️

```
    {}

        withdraw@withrevert(e, assets, receiver, owner)

    { lastReverted }
```

#### 19. function redeem must burn exactly shares from owner and sends assets of underlying tokens to receiver - Certora time out

```
    { 
        e.msg.sender != currentContract
        receiver != currentContract
        _receiverAssets + assets <= asset.totalSupply() 
    }

        _receiverAssets = asset.balanceOf(receiver)
        _totalAssets = totalAssets()
        _ownerShares = balanceOf(owner)
        _senderAllowance = allowance(owner, e.msg.sender)

        assets = redeem(e, shares, receiver, owner)

        totalAssets_ = totalAssets()
        receiverAssets_ = asset.balanceOf(receiver)
        ownerShares_ = balanceOf(owner)
        senderAllowance_ = allowance(owner, e.msg.sender)

    { 
        _totalAssets - assets == totalAssets_
        _receiverAssets + assets == receiverAssets_
        _ownerShares - shares == ownerShares_
        e.msg.sender != owner => 
            _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
            ||
             _senderAllowance - shares == senderAllowance_ 
    }
```

#### 20. function redeem reverts if there is not enough shares - Certora time out

```
    { 
        balanceOf(owner) < shares 
        || 
        e.msg.sender != owner && allowance(owner, e.msg.sender) < shares 
    }

        redeem@withrevert(e, shares, receiver, owner)

    { lastReverted }
```


#### 21. function applyNewTargetLtv updates the state variable targetLtv using newTargetLtv ✔️

```
    {}
        
        applyNewTargetLtv(e, newTargetLtv)

    { targetLtv() == newTargetLtv }
```

#### 22. function applyNewTargetLtv reverts the targetLtv exceeds getMaxLtv() ✔️

```
    { newTargetLtv > getMaxLtv() }
        
        applyNewTargetLtv@withrevert(e, newTargetLtv)

    { lastReverted }
```


#### 23. function receiveFlashLoan reverts the caller is not balancerVault ✔️

```
    { e.msg.sender != balancerVault() }
        
        receiveFlashLoan@withrevert(e, args)

    { lastReverted }
```


#### 24. function setPerformanceFee updates the state variable performanceFee using newPerformanceFee ✔️

```
    {}
        
        setPerformanceFee(e, newPerformanceFee)

    { performanceFee() == newPerformanceFee }
```

#### 25. function setPerformanceFee reverts if the value of the parameter newPerformanceFee is greater than 10^18 ✔️

```
    { newPerformanceFee > 10^18 }
    
        setPerformanceFee@withrevert(e, newPerformanceFee)

    { lastReverted }
```

#### 26. function setFloatPercentage updates the state variable performanceFee with the value provided by the parameter newPerformanceFee ✔️

```
    {}
    
        setFloatPercentage(e, newFloatPercentage)

    { floatPercentage() == newFloatPercentage }
```


#### 27. function setFloatPercentage reverts if the value of the parameter newFloatPercentage is greater than 10^18 ✔️

```
    { newFloatPercentage > 10^18 }
    
        setFloatPercentage@withrevert(e, newFloatPercentage)

    { lastReverted }
```

#### 28. function setTreasury updates the state variable treasury with the value provided by the parameter newTreasury ✔️

```
    {}
        
        setTreasury(e, newTreasury)

    { treasury() == newTreasury }
```

#### 29. function setTreasury reverts if address(0) ✔️

```
    {}
    
        setTreasury@withrevert(e, 0)

    { lastReverted }
```
