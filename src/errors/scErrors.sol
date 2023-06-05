// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

error InvalidTargetLtv();
error InvalidMaxLtv();
error InvalidFlashLoanCaller();
error InvalidSlippageTolerance();
error InvalidFloatPercentage();
error ZeroAddress();
error PleaseUseRedeemMethod();
error FeesTooHigh();
error TreasuryCannotBeZero();
error VaultNotUnderwater();
error CallerNotAdmin();
error CallerNotKeeper();
error NoProfitsToSell();
error EndUsdcBalanceTooLow();
error InvalidAllocationPercents();
error InsufficientDepositBalance();
error FloatBalanceTooSmall(uint256 actual, uint256 required);
error TokenSwapFailed(address from, address to);
error AmountReceivedBelowMin();
error ProtocolContainsFunds();
error FlashLoanAmountZero();
error ProtocolNotSupported(uint256 protocolId);
error ProtocolInUse(uint256 protocolId);
error FloatBalanceTooLow(uint256 actual, uint256 required);
