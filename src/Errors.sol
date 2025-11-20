// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Errors
 * @notice Centralized custom errors for IDO Manager contracts
 */

// ============================================
// ReservesManager Errors
// ============================================

/// @notice Thrown when zero address is provided where not allowed
error InvalidZeroAddress();

/// @notice Thrown when invalid token address is provided
error InvalidTokenAddress();

/// @notice Thrown when token is not a valid stablecoin (USDT, USDC, FLX)
error NotAStablecoin();

/// @notice Thrown when amount is zero or invalid
error InvalidAmount();

/// @notice Thrown when withdrawal amount exceeds available balance
error ExceedsWithdrawableAmount();

/// @notice Thrown when caller is not the reserves admin
error OnlyReservesAdmin();

/// @notice Thrown when IDO has not ended yet
error IDONotEnded();

/// @notice Thrown when there are no unsold tokens to withdraw
error NoUnsoldTokens();

/// @notice Thrown when there are no refunded tokens to withdraw
error NoRefundedTokens();

/// @notice Thrown when there are no penalty fees to withdraw
error NoPenaltyFees();

/// @notice Thrown when attempting to withdraw more than available
error InsufficientTokensAvailable();

// ============================================
// KYCRegistry Errors
// ============================================

/// @notice Thrown when KYC is required but user is not verified
error KYCRequired();

// ===========================================
// AdminManager Errors
// ===========================================

// @notice Thrown when caller is not an admin
error CallerNotAdmin();

// ============================================
// IDOManager Errors - Input Validation
// ============================================

/// @notice Thrown when token is not USDT, USDC, or FLX
error InvalidToken();

/// @notice Thrown when price is zero or invalid
error InvalidPrice();

/// @notice Thrown when IDO start time >= end time
error InvalidIDOTimeRange();

/// @notice Thrown when user allocation is zero
error InvalidUserAllocation();

/// @notice Thrown when total allocation is zero
error InvalidTotalAllocation();

/// @notice Thrown when vesting duration is zero
error InvalidVestingDuration();

/// @notice Thrown when unlock interval is zero
error InvalidUnlockInterval();

/// @notice Thrown when unlock interval exceeds vesting duration
error UnlockIntervalTooLarge();

/// @notice Thrown when TGE unlock percent exceeds 100%
error InvalidTGEUnlockPercent();

/// @notice Thrown when investment amount is below minimum allocation
error BelowMinAllocation();

// ============================================
// IDOManager Errors - State Validation
// ============================================

/// @notice Thrown when IDO has ended or allocation is full
error IDOEnded();

/// @notice Thrown when attempting to invest before IDO starts
error IDONotStarted();

/// @notice Thrown when user has already invested in this IDO
error AlreadyInvested();

/// @notice Thrown when static price for token is not set
error StaticPriceNotSet();

/// @notice Thrown when investment exceeds user's maximum allocation
error ExceedsUserAllocation();

/// @notice Thrown when investment exceeds IDO's total allocation
error ExceedsTotalAllocation();

/// @notice Thrown when attempting to claim before claim period starts
error ClaimNotStarted();

/// @notice Thrown when IDO token address has not been set
error TokenAddressNotSet();

/// @notice Thrown when user has no tokens available to claim
error NothingToClaim();

/// @notice Thrown when claim amount exceeds allocated tokens
error ClaimExceedsAllocated();

/// @notice Thrown when refund is not available at this time
error RefundNotAvailable();

/// @notice Thrown when user has no tokens available to refund
error NothingToRefund();

/// @notice Thrown when refund amount exceeds invested amount
error RefundExceedsInvested();

/// @notice Thrown when tokens are still locked (before unlock time)
error TokensLocked();

/// @notice Thrown when total allocation is invalid for phase calculation
error InvalidTotalAllocationForPhase();

/// @notice Thrown when IDO contract has insufficient token balance for claims
error InsufficientIDOContractBalance();
