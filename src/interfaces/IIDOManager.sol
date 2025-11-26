// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IIDOManager {
    /// @notice Represents the three phases of an IDO based on allocation progress
    /// @dev Phase is determined by totalAllocated divided by totalAllocation thirds
    enum Phase {
        Phase1,
        Phase2,
        Phase3
    }

    /// @notice Composite input structure for creating a new IDO
    /// @dev Contains all configuration parameters needed to initialize an IDO
    struct IDOInput {
        IDOInfo info;
        IDOBonuses bonuses;
        IDOSchedules schedules;
        RefundPenalties refundPenalties;
        RefundPolicy refundPolicy;
        uint256 initialPriceUsdt;
        uint256 fullRefundPriceUsdt;
    }

    /// @notice Core metadata and allocation parameters for an IDO
    /// @dev Stores token address, project ID, allocation limits, and runtime tracking
    struct IDOInfo {
        address tokenAddress;
        uint256 projectId;
        uint256 totalAllocated;
        uint256 minAllocationUSD;
        uint256 totalAllocationByUser;
        uint256 totalAllocation;
    }

    /// @notice Bonus percentages for each of the three IDO phases
    /// @dev Bonuses are applied to token purchases based on current phase. Scaled by HUNDRED_PERCENT / 100
    struct IDOBonuses {
        uint64 phase1BonusPercent;
        uint64 phase2BonusPercent;
        uint64 phase3BonusPercent;
    }

    /// @notice Main IDO record storing participation metrics and configuration
    /// @dev Combines runtime state with nested configuration structs
    struct IDO {
        uint256 totalParticipants;
        uint256 totalRaisedUSDT;
        IDOInfo info;
        IDOBonuses bonuses;
    }

    /// @notice Timing parameters for IDO lifecycle including TGE, vesting, and unlock schedules
    /// @dev All time values are unix timestamps (uint64) except durations which are in seconds
    struct IDOSchedules {
        uint64 idoStartTime;
        uint64 idoEndTime;
        uint64 claimStartTime;
        uint64 tgeTime;
        uint64 cliffDuration;
        uint64 vestingDuration;
        uint64 unlockInterval;
        uint64 twapCalculationWindowHours;
        uint64 timeoutForRefundAfterVesting;
        uint64 tgeUnlockPercent;
    }

    /// @notice Penalty percentages applied to refunds under different conditions
    /// @dev Penalties are expressed as parts per HUNDRED_PERCENT (10,000,000)
    struct RefundPenalties {
        uint64 fullRefundPenalty;
        uint64 fullRefundPenaltyBeforeTge;
        uint64 refundPenalty;
    }

    /// @notice Boolean flags controlling refund eligibility under various conditions
    /// @dev Defines which refund types are allowed during different IDO lifecycle stages
    struct RefundPolicy {
        uint64 fullRefundDuration;
        bool isRefundIfClaimedAllowed;
        bool isRefundUnlockedPartOnly;
        bool isRefundInCliffAllowed;
        bool isFullRefundBeforeTGEAllowed;
        bool isPartialRefundInCliffAllowed;
        bool isFullRefundInCliffAllowed;
        bool isPartialRefundInVestingAllowed;
        bool isFullRefundInVestingAllowed;
    }

    /// @notice Runtime tracking of refund activity and associated policies for an IDO
    /// @dev Aggregates total refunds and embeds refund policy configuration
    struct IDORefundInfo {
        uint256 totalRefunded;
        uint256 refundedBonus;
        uint256 totalRefundedUSDT;
        RefundPenalties refundPenalties;
        RefundPolicy refundPolicy;
    }

    /// @notice Pricing information for token valuation and refund eligibility
    /// @dev Stores initial price, full refund threshold, and TWAP for refund calculations
    struct IDOPricing {
        uint256 initialPriceUsdt;
        uint256 fullRefundPriceUsdt;
        uint256 twapPriceUsdt;
    }

    /// @notice Complete investment and claim state tracking for a single user in an IDO
    /// @dev Tracks invested amounts, allocated tokens, claims, refunds, and participation metadata
    struct UserInfo {
        uint256 investedUsdt;
        uint256 claimedTokens;
        uint256 claimedBonus;
        uint256 refundedTokens;
        uint256 refundedBonus;
        uint256 refundedUsdt;
        bool claimed;
        address investedToken;
        uint256 investedTokenAmount;
        uint256 investedTokenAmountRefunded;
        Phase investedPhase;
        uint256 allocatedTokens;
        uint256 allocatedBonus;
        uint64 investedTime;
    }

    event IDOCreated(
        uint256 indexed idoId,
        uint256 indexed projectId,
        uint64 idoStartTime,
        uint64 idoEndTime
    );
    event Investment(
        uint256 indexed idoId,
        address indexed investor,
        uint256 amountUsdt,
        address tokenIn,
        uint256 tokensBought,
        uint256 tokensBonus
    );
    event Refund(
        uint256 indexed idoId,
        address indexed investor,
        uint256 tokensToRefund,
        uint256 refundedAmount
    );
    event TokensClaimed(
        uint256 indexed idoId,
        address indexed investor,
        uint256 tokens
    );
    event StaticPriceSet(address indexed token, uint256 price);
    event ClaimStartTimeSet(uint256 idoId, uint64 claimStartTime);
    event TgeTimeSet(uint256 idoId, uint64 claimStartTime);
    event IdoTimeSet(uint256 idoId, uint64 idoStartTime, uint64 idoEndTime);
    event TokenAddressSet(uint256 idoId, address tokenAddress);
    event TwapSet(uint256 idoId, uint256 price);

    /// @notice Creates a new IDO with the provided configuration
    /// @dev Only callable by admin. Validates all input parameters and initializes IDO storage
    /// @param idoInput The complete IDO configuration including schedules, bonuses, and refund policies
    /// @return The unique identifier for the newly created IDO
    function createIDO(IDOInput calldata idoInput) external returns (uint256);

    /// @notice Allows a KYC-verified user to invest in an IDO
    /// @dev Requires KYC verification. Applies phase-based bonuses and validates allocation limits
    /// @param idoId The identifier of the IDO to invest in
    /// @param amount The amount of stablecoin to invest
    /// @param tokenIn The stablecoin address to invest with (USDT, USDC, or FLX)
    function invest(
        uint256 idoId,
        uint256 amount,
        address tokenIn
    ) external;

    /// @notice Processes a refund for a user's investment in an IDO
    /// @dev Validates refund eligibility based on policy, timing, and TWAP conditions. Applies penalties if applicable
    /// @param idoId The identifier of the IDO to refund from
    /// @param fullRefund True for full refund, false for partial refund
    function processRefund(uint256 idoId, bool fullRefund) external;

    /// @notice Claims unlocked tokens from an IDO based on vesting schedule
    /// @dev Calculates claimable amount based on TGE unlock, cliff, and vesting progress
    /// @param idoId The identifier of the IDO to claim tokens from
    function claimTokens(uint256 idoId) external;

    /// @notice Sets the TWAP price for an IDO in USDT
    /// @dev Only callable by admin. Used to determine full refund eligibility
    /// @param idoId The identifier of the IDO
    /// @param priceUsdt The TWAP price in USDT with 8 decimal precision
    function setTwapPriceUsdt(uint256 idoId, uint256 priceUsdt) external;

    /// @notice Sets a static price for a stablecoin
    /// @dev Only callable by admin. Used for USD value calculations
    /// @param token The stablecoin address
    /// @param price The price with 8 decimal precision
    function setStaticPrice(address token, uint256 price) external;

    /// @notice Sets the claim start time for an IDO
    /// @dev Only callable by admin. Users can claim tokens after this time
    /// @param idoId The identifier of the IDO
    /// @param _claimStartTime The unix timestamp when claims can begin
    function setClaimStartTime(uint256 idoId, uint64 _claimStartTime) external;

    /// @notice Sets the Token Generation Event (TGE) time for an IDO
    /// @dev Only callable by admin. Marks when vesting schedule begins
    /// @param idoId The identifier of the IDO
    /// @param _tgeTime The unix timestamp of the TGE
    function setTgeTime(uint256 idoId, uint64 _tgeTime) external;

    /// @notice Sets the start and end times for an IDO
    /// @dev Only callable by admin. Defines the investment window
    /// @param idoId The identifier of the IDO
    /// @param _idoStartTime The unix timestamp when IDO starts
    /// @param _idoEndTime The unix timestamp when IDO ends
    function setIdoTime(uint256 idoId, uint64 _idoStartTime, uint64 _idoEndTime) external;

    /// @notice Sets the project token address for an IDO
    /// @dev Only callable by admin. Must be set before users can claim tokens
    /// @param idoId The identifier of the IDO
    /// @param _address The project token contract address
    function setTokenAddress(uint256 idoId, address _address) external;

    /// @notice Calculates the total IDO allocation in USD
    /// @dev Converts totalAllocation to USD using the initial price
    /// @param idoId The identifier of the IDO
    /// @return The total allocation in USD with 18 decimal precision
    function getIDOTotalAllocationUSD(uint256 idoId) external view returns (uint256);

    /// @notice Calculates the per-user allocation limit in USD
    /// @dev Converts totalAllocationByUser to USD using the initial price
    /// @param idoId The identifier of the IDO
    /// @return The per-user allocation limit in USD with 18 decimal precision
    function getIDOTotalAllocationByUserUSD(uint256 idoId) external view returns (uint256);

    /// @notice Checks if a refund is currently available for the caller
    /// @dev Evaluates refund policy, timing, TWAP conditions, and user state
    /// @param idoId The identifier of the IDO
    /// @param fullRefund True to check full refund availability, false for partial
    /// @return True if refund is available, false otherwise
    function isRefundAvailable(uint256 idoId, bool fullRefund) external view returns (bool);

    /// @notice Calculates the amount of tokens available for a user to claim
    /// @dev Based on vesting schedule, TGE unlock, and previous claims/refunds
    /// @param idoId The identifier of the IDO
    /// @param user The address of the user
    /// @return The amount of tokens available to claim with 18 decimal precision
    function getTokensAvailableToClaim(uint256 idoId, address user) external view returns (uint256);

    /// @notice Calculates the amount of tokens available for a user to refund
    /// @dev Based on refund policy, vesting schedule, and previous refunds/claims
    /// @param idoId The identifier of the IDO
    /// @param user The address of the user
    /// @param fullRefund True for full refund calculation, false for partial
    /// @return The amount of tokens available to refund with 18 decimal precision
    function getTokensAvailableToRefund(uint256 idoId, address user, bool fullRefund) external view returns (uint256);

    /// @notice Calculates refundable tokens and the penalty-adjusted refund percentage
    /// @dev Returns both the token amount and the percentage after penalties
    /// @param idoId The identifier of the IDO
    /// @param user The address of the user
    /// @param fullRefund True for full refund calculation, false for partial
    /// @return totalRefundAmount The amount of tokens available to refund
    /// @return refundPercentAfterPenalty The percentage of value returned after penalties
    function getTokensAvailableToRefundWithPenalty(
        uint256 idoId,
        address user,
        bool fullRefund
    ) external view returns (uint256 totalRefundAmount, uint256 refundPercentAfterPenalty);

    /// @notice Returns the current phase of an IDO based on allocation progress
    /// @dev Phase is determined by dividing totalAllocated by totalAllocation into thirds
    /// @param idoId The identifier of the IDO
    /// @return The current phase (Phase1, Phase2, or Phase3)
    function currentPhase(uint256 idoId) external view returns (Phase);

    /// @notice Calculates the percentage of tokens unlocked based on vesting schedule
    /// @dev Considers TGE unlock, cliff, and vesting intervals
    /// @param idoId The identifier of the IDO
    /// @return The unlocked percentage as parts per HUNDRED_PERCENT (10,000,000)
    function getUnlockedPercent(uint256 idoId) external view returns (uint256);

    /// @notice Retrieves investment and claim information for a specific user
    /// @dev Returns key metrics about user's participation in an IDO
    /// @param idoId The identifier of the IDO
    /// @param userAddr The address of the user
    /// @return investedUsdt Total USDT value invested by the user
    /// @return allocatedTokens Total tokens allocated to the user (including bonuses)
    /// @return claimedTokens Total tokens claimed by the user
    /// @return refundedTokens Total tokens refunded by the user
    /// @return claimed Whether the user has claimed at least once
    function getUserInfo(
        uint256 idoId,
        address userAddr
    ) external view returns (
        uint256 investedUsdt,
        uint256 allocatedTokens,
        uint256 claimedTokens,
        uint256 refundedTokens,
        bool claimed
    );
}