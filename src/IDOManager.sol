// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./EmergencyWithdrawAdmin.sol";
import "./kyc/WithKYCRegistry.sol";
import "./admin_manager/WithAdminManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// interface IVoting {
//     function projects(
//         uint256
//     )
//         external
//         view
//         returns (
//             string memory name,
//             uint256 votes,
//             bool approved,
//             uint256 voteCount
//         );
// }

contract IDOManager is ReentrancyGuard, Ownable, EmergencyWithdrawAdmin, WithKYCRegistry, WithAdminManager {
    enum Phase {
        Phase1,
        Phase2,
        Phase3
    }

    struct IDOInput {
        uint256 projectId;
        uint64 idoStartTime;
        uint64 idoEndTime;

        uint256 totalAllocationByUserUSDT;
        uint256 totalAllocationUSDT;

        uint256 minAllocationUSDT;

        uint256 initialPriceUsdt;
        uint256 fullRefundPriceUsdt;
        uint64 cliffDuration;
        uint64 vestingDuration;
        uint64 unlockInterval;

        uint64 twapCalculationWindowHours;
        uint64 fullRefundDuration;

        uint64 tgeUnlockPercent;
        uint64 phase1BonusPercent;
        uint64 phase2BonusPercent;
        uint64 phase3BonusPercent;
        bool isRefundIfClaimedAllowed;
        bool isRefundUnlockedPartOnly;
        bool isRefundInCliffAllowed;

        uint256 timeoutForRefundAfterVesting;

        uint64 fullRefundPenaltyBeforeTge;
        uint64 fullRefundPenalty;
        uint64 refundPenalty;

        bool isPartialRefundBeforeTGEAllowed;
        bool isFullRefundBeforeTGEAllowed;

        bool isPartialRefundInCliffAllowed;
        bool isFullRefundInCliffAllowed;

        bool isPartialRefundInVestingAllowed;
        bool isFullRefundInVestingAllowed;

    }

    struct IDO {
        uint256 projectId;
        address tokenAddress;


// RUNTIME
        uint64 totalParticipants;
        uint256 totalAllocated;
        uint256 totalRefunded;
        uint256 refundedBonus;
        uint256 totalRefundedUSDT;
        uint256 totalRaisedUSDT;
// RUNTIME


// ALLOCATION SETTINGS
        uint256 minAllocationUSDT;

        uint256 totalAllocationByUser;
        uint256 totalAllocationByUserUSDT;

        uint256 totalAllocation;
        uint256 totalAllocationUSDT;
// ALLOCATION SETTINGS



// TIME PERIODS
        uint64 idoStartTime;
        uint64 idoEndTime;

        uint64 claimStartTime;
        uint64 tgeTime;
        uint64 cliffDuration;
        uint64 vestingDuration;
        uint64 unlockInterval;
        uint64 twapCalculationWindowHours;
        uint64 fullRefundDuration;
// TIME PERIODS


// PRICES
        uint256 initialPriceUsdt;
        uint256 fullRefundPriceUsdt;
        uint256 twapPriceUsdt;
// PRICES



// ---------------------------------------------------
// BONUS
        uint64 phase1BonusPercent;
        uint64 phase2BonusPercent;
        uint64 phase3BonusPercent;
// BONUS

        uint256 timeoutForRefundAfterVesting;

// REFUND PENALTY
        uint64 fullRefundPenalty;
        uint64 fullRefundPenaltyBeforeTge;
        uint64 refundPenalty;
// REFUND PENALTY


        uint64 tgeUnlockPercent;


        bool isRefundIfClaimedAllowed;
        bool isRefundUnlockedPartOnly;
        bool isRefundInCliffAllowed;


        bool isPartialRefundBeforeTGEAllowed;
        bool isFullRefundBeforeTGEAllowed;

        bool isPartialRefundInCliffAllowed;
        bool isFullRefundInCliffAllowed;

        bool isPartialRefundInVestingAllowed;
        bool isFullRefundInVestingAllowed;

// ---------------------------------------------------
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

    uint256 public idoCount;
    mapping(uint256 => IDO) public idos;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // IVoting public immutable voting;

    address public immutable usdt;
    address public immutable usdc;
    address public immutable flx;

    uint256 private constant DECIMALS = 1e18;
    uint32 private constant PERCENT_DECIMALS = 100000;
    uint256 private constant PRICE_DECIMALS = 1e8;

    uint8 private constant PHASE_DIVIDER = 3;
    uint16 private constant FLX_PRIORITY_PERIOD = 2 hours;

    mapping(address => uint256) public staticPrices;

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

    constructor(
        address _usdt,
        address _usdc,
        address _flx,
        address _kyc,
        address _emergencyWithdrawAdmin,
        address _adminManager,
        address _initialOwner
    ) Ownable(_initialOwner) WithAdminManager(_adminManager) 
      EmergencyWithdrawAdmin(_emergencyWithdrawAdmin) WithKYCRegistry(_kyc) {
        require(
            _usdt != address(0) &&
            _usdc != address(0) &&
            _flx != address(0),
            "Invalid token address"
        );
        usdt = _usdt;
        usdc = _usdc;
        flx = _flx;
    }

    function setKYCRegistry(
        address _kyc
    ) external override onlyOwner {
        _setKYCRegistry(_kyc);
    }

    function setAdminManager (
        address _adminManager
    ) external override onlyOwner {
        _setAdminManager(_adminManager);
    }

    function setClaimStartTime(
        uint256 idoId,
        uint64 _claimStartTime
    ) external onlyAdmin {
        IDO storage ido = idos[idoId];
        ido.claimStartTime = _claimStartTime;
        emit ClaimStartTimeSet(idoId, _claimStartTime);
    }

    function setTgeTime(
        uint256 idoId,
        uint64 _tgeTime
    ) external onlyAdmin {
        IDO storage ido = idos[idoId];
        ido.tgeTime = _tgeTime;
        emit TgeTimeSet(idoId, _tgeTime);
    }

    function setIdoTime(
        uint256 idoId,
        uint64 _idoStartTime,
        uint64 _idoEndTime
    ) external onlyAdmin {
        IDO storage ido = idos[idoId];
        ido.idoStartTime = _idoStartTime;
        ido.idoEndTime = _idoEndTime;
        emit IdoTimeSet(idoId, _idoStartTime, _idoEndTime);
    }

    function setTokenAddress(
        uint256 idoId,
        address _address
    ) external onlyAdmin {
        IDO storage ido = idos[idoId];
        ido.tokenAddress = _address;
        emit TokenAddressSet(idoId, _address);
    }

    function setStaticPrice(address token, uint256 price) external onlyAdmin {
        staticPrices[token] = price;
        emit StaticPriceSet(token, price);
    }

    function setTwapPriceUsdt(
        uint256 idoId,
        uint256 twapPriceUsdt
    ) external onlyAdmin {
        IDO storage ido = idos[idoId];
        ido.twapPriceUsdt = twapPriceUsdt;
        emit TwapSet(idoId, twapPriceUsdt);
    }

    function createIDO(IDOInput calldata idoInput) external onlyAdmin returns (uint256) {
        // (, , bool approved, ) = voting.projects(projectId);
        // require(approved, "Project not approved");
        require(idoInput.idoStartTime < idoInput.idoEndTime, "Invalid time range");
        require(idoInput.totalAllocationByUserUSDT > 0, "Invalid allocation");
        require(idoInput.totalAllocationUSDT > 0, "Invalid allocation");
        require(idoInput.initialPriceUsdt > 0, "Invalid initial price");
        require(idoInput.vestingDuration > 0, "Invalid vesting duration");
        require(idoInput.unlockInterval > 0, "Invalid unlock interval");
        require(idoInput.unlockInterval <= idoInput.vestingDuration, "Invalid unlock interval");

        // require(
        //     idoInput.totalAllocationByUserUSDT <= (idoInput.totalAllocationUSDT * 5) / 1000,
        //     "User allocation exceeds 0.5% limit"
        // );

        unchecked {
            idoCount++;
        }

        idos[idoCount] = IDO({
            projectId: idoInput.projectId,
            tokenAddress: address(0),
            idoStartTime: idoInput.idoStartTime,
            idoEndTime: idoInput.idoEndTime,
            totalAllocated: 0,
            totalRaisedUSDT: 0,
            unlockInterval: idoInput.unlockInterval,

            totalAllocationByUser: idoInput.totalAllocationByUserUSDT * PRICE_DECIMALS / idoInput.initialPriceUsdt,
            totalAllocationByUserUSDT: idoInput.totalAllocationByUserUSDT,

            totalAllocation: idoInput.totalAllocationUSDT * PRICE_DECIMALS / idoInput.initialPriceUsdt,
            totalAllocationUSDT: idoInput.totalAllocationUSDT,

            minAllocationUSDT: idoInput.minAllocationUSDT,

            initialPriceUsdt: idoInput.initialPriceUsdt,
            fullRefundPriceUsdt: idoInput.fullRefundPriceUsdt,
            twapPriceUsdt: 0,
            claimStartTime: 0,
            tgeTime: 0,
            cliffDuration: idoInput.cliffDuration,
            vestingDuration: idoInput.vestingDuration,
            tgeUnlockPercent: idoInput.tgeUnlockPercent,
            twapCalculationWindowHours: idoInput.twapCalculationWindowHours,
            fullRefundDuration: idoInput.fullRefundDuration,

            phase1BonusPercent: idoInput.phase1BonusPercent,
            phase2BonusPercent: idoInput.phase2BonusPercent,
            phase3BonusPercent: idoInput.phase3BonusPercent,

            totalParticipants: 0,
            totalRefunded: 0,
            refundedBonus: 0,
            totalRefundedUSDT: 0,

            isRefundIfClaimedAllowed: idoInput.isRefundIfClaimedAllowed,
            isRefundUnlockedPartOnly: idoInput.isRefundUnlockedPartOnly,
            isRefundInCliffAllowed: idoInput.isRefundInCliffAllowed,

            fullRefundPenalty: idoInput.fullRefundPenalty,
            fullRefundPenaltyBeforeTge: idoInput.fullRefundPenaltyBeforeTge,
            refundPenalty: idoInput.refundPenalty,



            isPartialRefundBeforeTGEAllowed: idoInput.isPartialRefundBeforeTGEAllowed,
            isFullRefundBeforeTGEAllowed: idoInput.isFullRefundBeforeTGEAllowed,

            isPartialRefundInCliffAllowed: idoInput.isPartialRefundInCliffAllowed,
            isFullRefundInCliffAllowed: idoInput.isFullRefundInCliffAllowed,

            isPartialRefundInVestingAllowed: idoInput.isPartialRefundInVestingAllowed,
            isFullRefundInVestingAllowed: idoInput.isFullRefundInVestingAllowed,

            timeoutForRefundAfterVesting: idoInput.timeoutForRefundAfterVesting
        });

        emit IDOCreated(idoCount, idoInput.projectId, idoInput.idoStartTime, idoInput.idoEndTime);
        return idoCount;
    }

    function getTokensAvailableToClaim(
        uint256 idoId,
        address user
    ) external view returns (uint256) {
        (uint256 tokens, uint256 bonus) = _getTokensAvailableToClaim(idos[idoId], userInfo[idoId][user]);
        return tokens + bonus;
    }

    function _getTokensAvailableToClaim(
        IDO memory ido,
        UserInfo memory user
    ) internal view returns (uint256, uint256) {
        uint256 unlockedPercent = _getUnlockedPercent(ido);
        require(unlockedPercent > 0, "Tokens are locked");

        uint256 unlockedWithoutBonus = (user.allocatedTokens - user.allocatedBonus) * unlockedPercent / (PERCENT_DECIMALS * 100);
        uint256 unlockedBonus = user.allocatedBonus * unlockedPercent / (PERCENT_DECIMALS * 100);

        uint256 claimedTokensWOBonus = user.claimedTokens - user.claimedBonus;

        return (
            unlockedWithoutBonus > claimedTokensWOBonus + user.refundedTokens ? unlockedWithoutBonus - claimedTokensWOBonus - user.refundedTokens : 0,
            unlockedBonus > user.claimedBonus + user.refundedBonus ? unlockedBonus - user.claimedBonus - user.refundedBonus : 0
        );
    }

    function _getDiscountedPrice(uint256 price, uint256 discount) internal pure returns (uint256) {
        uint256 discountAmount = (price * discount) / (PERCENT_DECIMALS * 100);
        return price - discountAmount;
    }

    function getTokensAvailableToRefund(
        uint256 idoId,
        address user,
        bool fullRefund
    ) external view returns (uint256) {
        (uint256 amount, ) = _getTokensAvailableToRefundAndReturnAmount(idos[idoId], userInfo[idoId][user], fullRefund);
        return amount;
    }

    function getTokensAvailableToRefundWithPenalty(
        uint256 idoId,
        address user,
        bool fullRefund
    ) external view returns (uint256, uint256) {
        (uint256 amount, uint256 percentToReturn) = _getTokensAvailableToRefundAndReturnAmount(idos[idoId], userInfo[idoId][user], fullRefund);
        return (amount, percentToReturn);
    }

    function _getTokensAvailableToRefundAndReturnAmount(
        IDO memory ido,
        UserInfo memory user,
        bool fullRefund
    ) internal view returns (uint256, uint256) {
        if (ido.tgeTime == 0 || block.timestamp < ido.tgeTime) {
            require(fullRefund, "Only full refund allowed before listing");
        }

        if (fullRefund) {
            if (block.timestamp >= ido.tgeTime + ido.twapCalculationWindowHours * 1 hours && block.timestamp <= ido.tgeTime + ido.twapCalculationWindowHours * 1 hours + ido.fullRefundDuration) {
                require(ido.twapPriceUsdt > 0 && ido.twapPriceUsdt <= ido.fullRefundPriceUsdt, "Full refund is available only if TWAP price is less than full refund price");
            }
        }

        uint256 totalToRefund;
        if (fullRefund) {
            require(!ido.isRefundUnlockedPartOnly, "Only unlocked tokens refund is allowed"); 
            totalToRefund = user.allocatedTokens - user.allocatedBonus;
        } else {
            uint256 unlockedPercent = _getUnlockedPercent(ido);
            require(unlockedPercent > 0, "Tokens are locked");
            totalToRefund = (user.allocatedTokens - user.allocatedBonus) * unlockedPercent / (PERCENT_DECIMALS * 100);
        }

        if (totalToRefund == 0) {
            return (0, 0);
        }

        uint256 penalty;

        if (block.timestamp >= ido.tgeTime + ido.twapCalculationWindowHours * 1 hours 
            && block.timestamp <= ido.tgeTime + ido.twapCalculationWindowHours * 1 hours + ido.fullRefundDuration
            && ido.twapPriceUsdt > 0 
            && ido.twapPriceUsdt <= ido.fullRefundPriceUsdt
        ) {
            penalty = 0;
        } else if (fullRefund) {
            penalty = ido.tgeTime == 0 || block.timestamp < ido.tgeTime ? ido.fullRefundPenaltyBeforeTge : ido.fullRefundPenalty;
        } else {
            penalty = ido.refundPenalty;
        }

        return (totalToRefund > user.refundedTokens + user.claimedTokens ? totalToRefund - user.refundedTokens - user.claimedTokens : 0, 100 * PERCENT_DECIMALS - penalty);
    }

    function claimTokens(uint256 idoId) external nonReentrant {
        IDO memory ido = idos[idoId];
        UserInfo storage user = userInfo[idoId][msg.sender];

        require(
            ido.claimStartTime > 0 && block.timestamp >= ido.claimStartTime,
            "Claim not started"
        );

        require(ido.tokenAddress != address(0), 'Token is not set yet');

        ERC20 token = ERC20(ido.tokenAddress);

        (uint256 tokensToClaim, uint256 bonusesToClaim) = _getTokensAvailableToClaim(ido, user);
        uint256 userTokensAmountToClaim = tokensToClaim + bonusesToClaim;
        require(userTokensAmountToClaim > 0, "Nothing to claim");
        require(userTokensAmountToClaim + user.refundedTokens + user.refundedBonus + user.claimedTokens <= user.allocatedTokens, "Claim exceeds allocated tokens");

        uint256 totalTokensInTokensDecimals = (userTokensAmountToClaim *
            (10 ** token.decimals())) / DECIMALS;

        user.claimed = true;
        user.claimedTokens += userTokensAmountToClaim;
        user.claimedBonus += bonusesToClaim;

        require(
            token.transfer(msg.sender, totalTokensInTokensDecimals),
            "Token transfer failed"
        );

        emit TokensClaimed(idoId, msg.sender, userTokensAmountToClaim);
    }

    function _currentPhase(IDO memory ido) internal pure returns (Phase) {
        require(ido.totalAllocation > 0, "Invalid total allocation");

        uint256 oneThird = ido.totalAllocation / 3;

        if (ido.totalAllocated < oneThird) {
            return Phase.Phase1;
        } else if (ido.totalAllocated < 2 * oneThird) {
            return Phase.Phase2;
        } else {
            return Phase.Phase3;
        }
    }

    function currentPhase(uint256 idoId) external view returns (Phase) {
        IDO memory ido = idos[idoId];
        return _currentPhase(ido);
    }

    function _getPhaseBonus(IDO memory ido) internal pure returns (uint256, Phase) {
        Phase phase = _currentPhase(ido);
        if (phase == Phase.Phase1) return (ido.phase1BonusPercent, phase);
        if (phase == Phase.Phase2) return (ido.phase2BonusPercent, phase);
        return (ido.phase3BonusPercent, phase);
    }

    function getUnlockedPercent(uint256 idoId) public view returns (uint256) {
        return _getUnlockedPercent(idos[idoId]);
    }

    function _getUnlockedPercent(
        IDO memory ido
    ) internal view returns (uint256) {
        if (ido.tgeTime == 0 || block.timestamp < ido.tgeTime) {
            return 0;
        }

        if (block.timestamp <= ido.tgeTime + ido.cliffDuration) {
            return ido.tgeUnlockPercent;
        }

        uint256 vestingEndTime = ido.tgeTime + ido.cliffDuration + ido.vestingDuration;

        if (block.timestamp > vestingEndTime) {
            return 100 * PERCENT_DECIMALS;
        }

        uint256 vestingTime = block.timestamp - ido.tgeTime - ido.cliffDuration;

        // uint256 vestingPercent = (vestingTime *
        //     (100 * PERCENT_DECIMALS - ido.tgeUnlockPercent)) /
        //     ido.vestingDuration;


        uint256 intervalsCompleted = vestingTime / ido.unlockInterval;
        uint256 totalIntervals = ido.vestingDuration / ido.unlockInterval;
        
        if (ido.vestingDuration % ido.unlockInterval != 0) {
            totalIntervals += 1;
        }
        
        uint256 vestingPercent = (intervalsCompleted *
            (100 * PERCENT_DECIMALS - ido.tgeUnlockPercent)) /
            totalIntervals;

        return ido.tgeUnlockPercent + vestingPercent;
    }

    function isRefundAvailable(uint256 idoId, bool fullRefund) external view returns (bool) {
        return _isRefundAllowed(idos[idoId], userInfo[idoId][msg.sender], fullRefund);
    }

    function _isRefundAllowed(IDO memory ido, UserInfo memory user, bool fullRefund) internal view returns (bool) {
        if (!ido.isRefundIfClaimedAllowed && user.claimed) {
            return false;
        }

        if (!ido.isRefundInCliffAllowed && ido.tgeTime != 0 && block.timestamp > ido.tgeTime && block.timestamp <= ido.tgeTime + ido.cliffDuration) {
            return false;
        }

        require(ido.tgeTime == 0 || block.timestamp <= ido.tgeTime + ido.cliffDuration + ido.vestingDuration + ido.timeoutForRefundAfterVesting, "Refund after vesting is not allowed");

        if (ido.tgeTime == 0 || block.timestamp < ido.tgeTime) {
            if (fullRefund) {
                require(ido.isFullRefundBeforeTGEAllowed, "Full refund before TGE is not allowed");
            } else {
                require(ido.isPartialRefundBeforeTGEAllowed, "Partial refund before TGE is not allowed");
            }
        }

        if (
            !(
                block.timestamp >= ido.tgeTime + ido.twapCalculationWindowHours * 1 hours && 
                block.timestamp <= ido.tgeTime + ido.twapCalculationWindowHours * 1 hours + ido.fullRefundDuration &&
                ido.twapPriceUsdt > 0 && ido.twapPriceUsdt <= ido.fullRefundPriceUsdt
            )
        ) {
            if (block.timestamp > ido.tgeTime + ido.cliffDuration) {
                if (fullRefund) {
                    require(ido.isFullRefundInVestingAllowed, "Full refund in vesting is not allowed");
                } else {
                    require(ido.isPartialRefundInVestingAllowed, "Partial refund in vesting is not allowed");
                }
            }

            if (block.timestamp >= ido.tgeTime && block.timestamp <= ido.tgeTime + ido.cliffDuration) {
                if (fullRefund) {
                    require(ido.isFullRefundInCliffAllowed, "Full refund in cliff is not allowed");
                } else {
                    require(ido.isPartialRefundInCliffAllowed, "Partial refund in cliff is not allowed");
                }
            }
        }

        return true;
    }

    function processRefund(uint256 idoId, bool fullRefund) external nonReentrant {
        IDO storage ido = idos[idoId];
        UserInfo storage user = userInfo[idoId][msg.sender];

        require(_isRefundAllowed(ido, user, fullRefund), "Refund is not available right now");

        (uint256 tokensToRefund, uint256 percentToReturn) = _getTokensAvailableToRefundAndReturnAmount(
            ido,
            user,
            fullRefund
        );

        require(tokensToRefund > 0, "Nothing to refund");
        require(tokensToRefund + user.refundedTokens + user.refundedBonus + user.claimedTokens <= user.allocatedTokens, "Refund exceeds allocated tokens");

        uint256 bonusToSub;

        bonusToSub = user.allocatedBonus - user.refundedBonus - user.claimedBonus;

        user.refundedBonus += bonusToSub;

        user.refundedTokens += tokensToRefund;

        ido.totalRefunded += tokensToRefund;
        ido.refundedBonus += bonusToSub;

        // @note What is the formula below? Fix decimals calculation and readability
        uint256 refundedUsdt = tokensToRefund * ido.initialPriceUsdt * percentToReturn / (PRICE_DECIMALS * 100 * PERCENT_DECIMALS);

        ido.totalRefundedUSDT += refundedUsdt;
        user.refundedUsdt += refundedUsdt;

        // @note Code duplication with "refundedUsdt"
        uint256 amountToRefund = (tokensToRefund * ido.initialPriceUsdt * percentToReturn) / (staticPrices[user.investedToken] * 100 * PERCENT_DECIMALS);


        ERC20 token = ERC20(user.investedToken);
        uint256 investedTokenToRefund = (amountToRefund *
            10 ** token.decimals()) / DECIMALS;

        require(
            user.investedTokenAmountRefunded + investedTokenToRefund <=
                user.investedTokenAmount,
            "Refund exceeds invested amount"
        );

        user.investedTokenAmountRefunded += investedTokenToRefund;
        // ido.totalRaisedUSDT -= amountToRefund * staticPrices[user.investedToken] / PRICE_DECIMALS;

        require(
            token.transfer(msg.sender, investedTokenToRefund),
            "Token transfer failed"
        );

        emit Refund(idoId, msg.sender, tokensToRefund, amountToRefund);
    }

    function invest(
        uint256 idoId,
        uint256 amount,
        address tokenIn
    ) external nonReentrant onlyKYC {
        require(
            tokenIn == usdt || tokenIn == usdc || tokenIn == flx,
            "Invalid token"
        );

        IDO storage ido = idos[idoId];
        UserInfo storage user = userInfo[idoId][msg.sender];

        require(
            ido.totalAllocated < ido.totalAllocation && block.timestamp <= ido.idoEndTime,
            "IDO is ended"
        );

        require(
            block.timestamp >= ido.idoStartTime,
            "IDO is not started yet"
        );

        require(ido.initialPriceUsdt > 0, "Initial price not set");

        require(user.investedToken == address(0), "You already invested");

        unchecked {
            ido.totalParticipants ++;
        }

        // if (block.timestamp <= ido.idoStartTime + FLX_PRIORITY_PERIOD) {
        //     require(
        //         IERC20(flx).balanceOf(msg.sender) > 0,
        //         "FLX required in first 2h"
        //     );
        // }

        uint256 staticPrice = staticPrices[tokenIn];
        require(staticPrice > 0, "Static price not set");

        ERC20 _tokenIn = ERC20(tokenIn);

        // ? normalized to 18 decimals
        uint256 normalizedAmount = (amount * DECIMALS) / (10 ** _tokenIn.decimals());
        // ? invested tokens converted to USDT
        uint256 amountInUSD = (normalizedAmount * staticPrice) / PRICE_DECIMALS;

        require(amountInUSD >= ido.minAllocationUSDT, "Amount must be greater than min allocation");

        (uint256 bonusPercent, Phase phaseNow) = _getPhaseBonus(ido);

        user.investedUsdt += amountInUSD;
        user.investedTokenAmount += amount;
        unchecked {
            user.investedTime = uint64(block.timestamp);
        }
        user.investedPhase = phaseNow;
        user.investedToken = tokenIn;

        // uint256 salePrice = _getDiscountedPrice(ido.initialPriceUsdt, _getPhaseBonus(ido));

        // uint256 tokensBought = (amountInUSD * PRICE_DECIMALS) / salePrice;

        uint256 bonusesMultiplier = bonusPercent + 100 * PERCENT_DECIMALS;

        uint256 tokensBought = (amountInUSD *
            PRICE_DECIMALS *
            bonusesMultiplier) /
            ido.initialPriceUsdt /
            (PERCENT_DECIMALS * 100);

        uint256 tokensBonus = tokensBought - (amountInUSD * PRICE_DECIMALS) / ido.initialPriceUsdt;

// allocations
        require(
            tokensBought + user.allocatedTokens - user.refundedTokens - user.refundedBonus <= ido.totalAllocationByUser,
            "Exceeds max allocation per user"
        );
        require(
            tokensBought + ido.totalAllocated - ido.totalRefunded - ido.refundedBonus <= ido.totalAllocation,
            "Exceeds total allocation"
        );
// allocations

        user.allocatedTokens += tokensBought;
        user.allocatedBonus += tokensBonus;
        ido.totalAllocated += tokensBought;
        ido.totalRaisedUSDT += amountInUSD;

        require(
            _tokenIn.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        emit Investment(idoId, msg.sender, amountInUSD, tokenIn, normalizedAmount, tokensBought, tokensBonus);
    }

    function _getUserAvailableTokens(UserInfo memory user) internal pure returns (uint256) {
        return user.allocatedTokens - user.claimedTokens - user.refundedTokens;
    }

    function getUserInfo(
        uint256 idoId,
        address userAddr
    )
        external
        view
        returns (
            uint256 investedUsdt,
            uint256 allocatedTokens,
            uint256 claimedTokens,
            uint256 refundedTokens,
            bool claimed
        )
    {
        UserInfo storage info = userInfo[idoId][userAddr];
        return (
            info.investedUsdt,
            info.allocatedTokens,
            info.claimedTokens,
            info.refundedTokens,
            info.claimed
        );
    }
}
