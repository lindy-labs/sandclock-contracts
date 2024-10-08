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
error EndDaiBalanceTooLow();
error EndAssetBalanceTooLow();
error InsufficientDepositBalance();
error AmountReceivedBelowMin();
error FlashLoanAmountZero();
error ProtocolNotSupported(uint256 adapterId);
error ProtocolInUse(uint256 adapterId);
error FloatBalanceTooLow(uint256 actual, uint256 required);
error TokenOutNotAllowed(address token);
error TargetTokenMismatch();
error InvestedAmountNotWithdrawn();

library Check {
    function isZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }
}
