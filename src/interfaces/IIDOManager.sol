// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIDOManager {
    enum Phase {
        Phase1,
        Phase2,
        Phase3
    }

    struct IDOInput {
        IDOInfo info;
        IDOBonuses bonuses;
        IDOSchedules schedules;
        RefundPenalties refundPenalties;
        RefundPolicy refundPolicy;
        uint256 initialPriceUsdt;
        uint256 fullRefundPriceUsdt;
    }

    struct IDOInfo {
        address tokenAddress;
        uint256 projectId;
        uint256 totalAllocated;
        uint256 minAllocation;
        uint256 totalAllocationByUser;
        uint256 totalAllocation;
    }

    struct IDOBonuses {
        uint64 phase1BonusPercent;
        uint64 phase2BonusPercent;
        uint64 phase3BonusPercent;
    }

    struct IDO {
        uint256 totalParticipants;
        uint256 totalRaisedUSDT;
        IDOInfo info;
        IDOBonuses bonuses;
    }

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

    struct RefundPenalties {
        uint64 fullRefundPenalty;
        uint64 fullRefundPenaltyBeforeTge;
        uint64 refundPenalty;
    }

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

    struct IDORefundInfo {
        uint256 totalRefunded;
        uint256 refundedBonus;
        uint256 totalRefundedUSDT;
        RefundPenalties refundPenalties;
        RefundPolicy refundPolicy;
    }

    struct IDOPricing {
        uint256 initialPriceUsdt;
        uint256 fullRefundPriceUsdt;
        uint256 twapPriceUsdt;
    }

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
        uint256 amountToken,
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

    function createIDO(IDOInput calldata idoInput) external returns (uint256);

    function invest(
        uint256 idoId,
        uint256 amount,
        address tokenIn
    ) external;

    function processRefund(uint256 idoId, bool fullRefund) external;

    function claimTokens(uint256 idoId) external;

    function setTwapPriceUsdt(uint256 idoId, uint256 priceUsdt) external;

    function setStaticPrice(address token, uint256 price) external;
    
    // TODO finish interface methods
}