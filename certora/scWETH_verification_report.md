![Certora](https://hackmd.io/_uploads/H1yqrfBZY.png)
# Formal Verification of scWETH contract  
 
## Summary

The Certora Prover has partially proved the implementation of the scWETH contract is correct with respect to formal specifications written by the security team of Lindy Labs, but Certora timed out on several rules. The common characteristics of the rules are that they verify functions that call the `receiveFlashLoan` function. The `receiveFlashLoan` is the most complicated function in the contract because it interacts 7 external contracts.

The team also performed a manual audit of these contracts.

## List of Issues Discovered

# Overview of the verification

## Description of the scWETH contract

The scWETH contract inherits the properties of ERC-4626, a standard that simplifies and harmonizes the technical requirements of yield-bearing vaults. This standard provides a uniform interface for yield-bearing vaults that are represented by tokenized shares of an ERC-20 token. Furthermore, ERC-4626 has an elective add-on for vaults that utilize ERC-20 tokens, which includes fundamental functionalities such as token deposit, withdrawal, and balance inquiry.

## Assumptions and Simplifications

We made the following assumptions during the verification process:

- We unroll loops by max 1 time. Violations that require a loop to execute more than 3 times will not be detected.
- When verifying contracts that make external calls, we assume that those calls can have arbitrary side effects outside of the contracts, but that they do not affect the state of the contract being verified. This means that some reentrancy bugs may not be caught. However, the previous audits should have already covered all the possible reentrancy attacks

## Verification Conditions
### Notation
✔️ indicates the rule is formally verified on the latest reviewed commit. Footnotes describe any simplifications or assumptions used while verifying the rules (beyond the general assumptions listed above).


In this document, verification conditions are either shown as logical formulas or Hoare triples of the form {p} C {q}. A verification condition given by a logical formula denotes an invariant that holds if every reachable state satisfies the condition.

Hoare triples of the form {p} C {q} holds if any non-reverting execution of program C that starts in a state satsifying the precondition p ends in a state satisfying the postcondition q. The notation {p} C@withrevert {q} is similar but applies to both reverting and non-reverting executions. Preconditions and postconditions are similar to the Solidity require and statements.

Formulas relate the results of method calls. In most cases, these methods are getters defined in the contracts, but in some cases they are getters we have added to our harness or definitions provided in the rules file. Undefined variables in the formulas are treated as arbitrary: the rule is checked for every possible value of the variables.

## scWETH

### Rules

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