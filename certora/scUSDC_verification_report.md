![Certora](https://hackmd.io/_uploads/H1yqrfBZY.png)
# Formal Verification of scUSDC contract  
 
## Summary

The Certora Prover proved the implementation of the scUSDC contract is correct with respect to formal specifications written by the security team of Lindy Labs.  The team also performed a manual audit of these contracts.

## List of Issues Discovered

# Overview of the verification

## Description of the scUSDC contract

The scUSDC contract inherits the properties of ERC-4626, a standard that simplifies and harmonizes the technical requirements of yield-bearing vaults. This standard provides a uniform interface for yield-bearing vaults that are represented by tokenized shares of an ERC-20 token. Furthermore, ERC-4626 has an elective add-on for vaults that utilize ERC-20 tokens, which includes fundamental functionalities such as token deposit, withdrawal, and balance inquiry.

## Assumptions and Simplifications

We made the following assumptions during the verification process:

- We unroll loops by max 3 times. Violations that require a loop to execute more than 3 times will not be detected.
- When verifying contracts that make external calls, we assume that those calls can have arbitrary side effects outside of the contracts, but that they do not affect the state of the contract being verified. This means that some reentrancy bugs may not be caught. However, the previous audits should have already covered all the possible reentrancy attacks

## Verification Conditions
### Notation
✔️ indicates the rule is formally verified on the latest reviewed commit. Footnotes describe any simplifications or assumptions used while verifying the rules (beyond the general assumptions listed above).


In this document, verification conditions are either shown as logical formulas or Hoare triples of the form {p} C {q}. A verification condition given by a logical formula denotes an invariant that holds if every reachable state satisfies the condition.

Hoare triples of the form {p} C {q} holds if any non-reverting execution of program C that starts in a state satsifying the precondition p ends in a state satisfying the postcondition q. The notation {p} C@withrevert {q} is similar but applies to both reverting and non-reverting executions. Preconditions and postconditions are similar to the Solidity require and statements.

Formulas relate the results of method calls. In most cases, these methods are getters defined in the contracts, but in some cases they are getters we have added to our harness or definitions provided in the rules file. Undefined variables in the formulas are treated as arbitrary: the rule is checked for every possible value of the variables.

## scUSDC

### Rules

#### 1. maxDeposit returns the maximum expected value of a deposit ✔️
    
```
    maxDeposit(receiver) == 2^256 - 1
```

#### 2. maxMint returns the maximum expected value of a mint ✔️
    
```
    maxMint(receiver) == 2^256 - 1
```

#### 3. deposit must revert if all of assets cannot be deposited ✔️
    
```
    { asset.balanceOf(e.msg.sender) < assets }
    
        deposit@withrevert(e, assets, receiver);

    { lastReverted }
```

#### 4. redeem reverts if there is not enough shares ✔️
    
```
    { 
        balanceOf(owner) < shares 
        || 
        e.msg.sender != owner && allowance(owner, e.msg.sender) < shares 
    }
        
        redeem@withrevert(e, shares, receiver, owner);
    
    { lastReverted }
```


#### 5. changeLeverage updates the state variable flashloanLtv using newFlashloanLtv ✔️
    
```
    {}
    
        changeLeverage(e, newFlashloanLtv);

    { flashloanLtv() == newFlashloanLtv }
```

#### 6. changeLeverage reverts if newFlashloanLtv exceeds ethWstEthMaxLtv ✔️
    
```
    { newFlashloanLtv > ethWstEthMaxLtv() }
    
        changeLeverage@withrevert(e, newFlashloanLtv);
    
    { lastReverted }
```

#### 7. receiveFlashloan reverts if the caller is not the balancerVault ✔️
    
```
    { e.msg.sender != balancerVault() }
    
        receiveFlashLoan@withrevert(e, args);
    
    { lastReverted }
```

#### 8. setPerformanceFee updates the state variable performanceFee using newPerformanceFee ✔️
    
```
    {}
    
        setPerformanceFee(e, newPerformanceFee);
    
    { performanceFee() == newPerformanceFee }
```

#### 9. setFloatPercentage updates the state variable performanceFee with the value provided by the parameter newPerformanceFee ✔️
    
```
    {}
        
        setFloatPercentage(e, newFloatPercentage);
    
    { floatPercentage() == newFloatPercentage }
```

#### 10. setTreasury updates the state variable treasury with the value provided by the parameter newTreasury ✔️
    
```
    {}
        
        setTreasury(e, newTreasury);
    
    { treasury() == newTreasury }
```

#### 11. setPerformanceFee reverts if the value of the parameter newPerformanceFee is greater than 10^18 ✔️
    
```
    { newPerformanceFee > 10^18 }
        
        setPerformanceFee@withrevert(e, newPerformanceFee);
    
    { lastReverted }
```

#### 12. setFloatPercentage reverts if the value of the parameter newFloatPercentage is greater than 10^18 ✔️
    
```
    { newFloatPercentage > 10^18 }
    
        setFloatPercentage@withrevert(e, newFloatPercentage);
    
    { lastReverted }
```

#### 13. setTreasury reverts if address(0) ✔️
    
```
    {}
    
        setTreasury@withrevert(e, 0);
    
    { lastReverted }
```
