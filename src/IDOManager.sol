// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ReservesManager.sol";
import "./kyc/WithKYCRegistry.sol";
import "./admin_manager/WithAdminManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IIDOManager.sol";
import "./interfaces/IReservesManager.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Errors.sol";

contract IDOManager is IIDOManager, ReentrancyGuard, Ownable, ReservesManager, WithKYCRegistry, WithAdminManager {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 public idoCount;

    mapping(uint256 => IDO) public idos;
    mapping(uint256 idoId => IDOSchedules) public idoSchedules;
    mapping(uint256 idoId => IDORefundInfo) public idoRefundInfo;
    mapping(uint256 idoId => IDOPricing) public idoPricing;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Reserves tracking - stablecoins deposited per IDO per token
    mapping(uint256 => mapping(address => uint256)) public totalRaisedInToken;
    // Reserves tracking - stablecoins refunded per IDO per token
    mapping(uint256 => mapping(address => uint256)) public totalRefundedInToken;
    // Reserves tracking - total tokens claimed by users per IDO
    mapping(uint256 => uint256) public totalClaimedTokens;

    uint256 private constant DECIMALS = 1e18;
    uint32 private constant HUNDRED_PERCENT = 10_000_000;
    uint256 private constant PRICE_DECIMALS = 1e8;

    uint8 private constant PHASE_DIVIDER = 3;
    uint16 private constant FLX_PRIORITY_PERIOD = 2 hours;

    mapping(address => uint256) public staticPrices;

    constructor(
        address _usdt,
        address _usdc,
        address _flx,
        address _kyc,
        address _reservesAdmin,
        address _adminManager,
        address _initialOwner
    ) Ownable(_initialOwner) WithAdminManager(_adminManager)
      ReservesManager(_reservesAdmin, _usdt, _usdc, _flx) WithKYCRegistry(_kyc) {
    }

    /// @inheritdoc IIDOManager
    function createIDO(IDOInput calldata idoInput) external onlyAdmin returns (uint256) {
        IDOInfo memory _idoInputInfo = idoInput.info;
        IDOSchedules memory _idoInputSchedules = idoInput.schedules;
        RefundPolicy memory _inputRefundPolicy = idoInput.refundPolicy;
        RefundPenalties memory _inputRefundPenalties = idoInput.refundPenalties;
        
        _validateIDOInputs(idoInput, _idoInputInfo, _idoInputSchedules);

        uint256 idoId = ++idoCount;

        idoSchedules[idoId] = IDOSchedules({
            idoStartTime: _idoInputSchedules.idoStartTime,
            idoEndTime: _idoInputSchedules.idoEndTime,
            claimStartTime: 0,
            tgeTime: 0,
            cliffDuration: _idoInputSchedules.cliffDuration,
            vestingDuration: _idoInputSchedules.vestingDuration,
            unlockInterval: _idoInputSchedules.unlockInterval,
            tgeUnlockPercent: _idoInputSchedules.tgeUnlockPercent,
            timeoutForRefundAfterVesting: _idoInputSchedules.timeoutForRefundAfterVesting,
            twapCalculationWindowHours: _idoInputSchedules.twapCalculationWindowHours
        });

        idoRefundInfo[idoId] = IDORefundInfo({
            totalRefunded: 0,
            refundedBonus: 0,
            totalRefundedUSDT: 0,
            refundPenalties: RefundPenalties({
                fullRefundPenalty: _inputRefundPenalties.fullRefundPenalty,
                fullRefundPenaltyBeforeTge: _inputRefundPenalties.fullRefundPenaltyBeforeTge,
                refundPenalty: _inputRefundPenalties.refundPenalty
            }),
            refundPolicy: RefundPolicy({
                fullRefundDuration: _inputRefundPolicy.fullRefundDuration,
                isRefundIfClaimedAllowed: _inputRefundPolicy.isRefundIfClaimedAllowed,
                isRefundUnlockedPartOnly: _inputRefundPolicy.isRefundUnlockedPartOnly,
                isRefundInCliffAllowed: _inputRefundPolicy.isRefundInCliffAllowed,
                isFullRefundBeforeTGEAllowed: _inputRefundPolicy.isFullRefundBeforeTGEAllowed,
                isPartialRefundInCliffAllowed: _inputRefundPolicy.isPartialRefundInCliffAllowed,
                isFullRefundInCliffAllowed: _inputRefundPolicy.isFullRefundInCliffAllowed,
                isPartialRefundInVestingAllowed: _inputRefundPolicy.isPartialRefundInVestingAllowed,
                isFullRefundInVestingAllowed: _inputRefundPolicy.isFullRefundInVestingAllowed
            })
        });

        idoPricing[idoId] = IDOPricing({
            initialPriceUsdt: idoInput.initialPriceUsdt,
            fullRefundPriceUsdt: idoInput.fullRefundPriceUsdt,
            twapPriceUsdt: 0
        });

        idos[idoId] = IDO({
            totalParticipants: 0,
            totalRaisedUSDT: 0,
            info: IDOInfo({
                projectId: _idoInputInfo.projectId,
                tokenAddress: _idoInputInfo.tokenAddress,
                totalAllocated: 0,
                minAllocationUSD: _idoInputInfo.minAllocationUSD,
                totalAllocationByUser: _idoInputInfo.totalAllocationByUser,
                totalAllocation: _idoInputInfo.totalAllocation
            }),
            bonuses: IDOBonuses({
                phase1BonusPercent: idoInput.bonuses.phase1BonusPercent,
                phase2BonusPercent: idoInput.bonuses.phase2BonusPercent,
                phase3BonusPercent: idoInput.bonuses.phase3BonusPercent
            })
        });

        emit IDOCreated(idoId, _idoInputInfo.projectId, _idoInputSchedules.idoStartTime, _idoInputSchedules.idoEndTime);
        return idoId;
    }

    /// @inheritdoc IIDOManager
    function invest(
        uint256 idoId,
        uint256 amount,
        address tokenIn
    ) external nonReentrant onlyKYC {
        require(tokenIn == USDT || tokenIn == USDC || tokenIn == FLX, InvalidToken());

        IDO storage ido = idos[idoId];
        IDOSchedules memory schedules = idoSchedules[idoId];
        IDORefundInfo memory refundInfo = idoRefundInfo[idoId];
        IDOPricing memory pricing = idoPricing[idoId];
        UserInfo memory user = userInfo[idoId][msg.sender];

        _validateInvestmentState(ido, schedules, user, pricing);

        uint256 amountInUSD = _calculateAmountInUSD(tokenIn, amount);

        require(amountInUSD >= ido.info.minAllocationUSD, BelowMinAllocation());

        (uint256 bonusPercent, Phase phaseNow) = _getPhaseBonus(ido);

        uint256 tokensBought = _calculateTokensBought(amountInUSD, bonusPercent, pricing.initialPriceUsdt);
        uint256 tokensBonus = tokensBought - _convertFromUSDT(amountInUSD, pricing.initialPriceUsdt);

        _checkAllocationLimits(tokensBought, ido, user, refundInfo);        

        _saveUserInvestment(
            idoId,
            amount,
            amountInUSD,
            tokenIn,
            tokensBought,
            tokensBonus,
            phaseNow
        );
        
        ido.totalParticipants ++;
        ido.info.totalAllocated += tokensBought;
        ido.totalRaisedUSDT += amountInUSD;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount);

        // Track stablecoin raised for this IDO
        totalRaisedInToken[idoId][tokenIn] += amount;

        emit Investment(idoId, msg.sender, amountInUSD, tokenIn, tokensBought, tokensBonus);
    }

    /// @inheritdoc IIDOManager
    function claimTokens(uint256 idoId) external nonReentrant {
        IDO memory ido = idos[idoId];
        IDOSchedules memory schedules = idoSchedules[idoId];
        UserInfo storage user = userInfo[idoId][msg.sender];

        require(schedules.claimStartTime > 0 && block.timestamp >= schedules.claimStartTime, ClaimNotStarted());
        require(ido.info.tokenAddress != address(0), TokenAddressNotSet());

        ERC20 token = ERC20(ido.info.tokenAddress);

        (uint256 tokensToClaim, uint256 bonusesToClaim) = _getTokensAvailableToClaim(schedules, user);
        uint256 userTokensAmountToClaim = tokensToClaim + bonusesToClaim;
        require(userTokensAmountToClaim > 0, NothingToClaim());
        require(userTokensAmountToClaim + user.refundedTokens + user.refundedBonus + user.claimedTokens <= user.allocatedTokens, ClaimExceedsAllocated());

        uint256 totalTokensInTokensDecimals = userTokensAmountToClaim.mulDiv(10 ** token.decimals(), DECIMALS);
        require(token.balanceOf(address(this)) >= totalTokensInTokensDecimals, InsufficientIDOContractBalance());

        user.claimed = true;
        user.claimedTokens += userTokensAmountToClaim;
        user.claimedBonus += bonusesToClaim;

        // Track total claimed tokens for this IDO
        totalClaimedTokens[idoId] += userTokensAmountToClaim;

        IERC20(address(token)).safeTransfer(msg.sender, totalTokensInTokensDecimals);

        emit TokensClaimed(idoId, msg.sender, userTokensAmountToClaim);
    }

    /// @inheritdoc IIDOManager
    function processRefund(uint256 idoId, bool fullRefund) external nonReentrant {
        IDOSchedules memory schedules = idoSchedules[idoId];
        IDORefundInfo memory refundInfo = idoRefundInfo[idoId];
        IDOPricing memory pricing = idoPricing[idoId];
        UserInfo memory user = userInfo[idoId][msg.sender];

        require(_isRefundAllowed(schedules, refundInfo, pricing, user, fullRefund), RefundNotAvailable());

        uint256 tokensToRefund = _getTokensAvailableToRefund(
            schedules,
            refundInfo,
            pricing,
            user,
            fullRefund
        );

        require(tokensToRefund > 0, NothingToRefund());

        uint256 percentToReturn = _getRefundPercentAfterPenalty(
            schedules,
            refundInfo,
            pricing,
            user,
            fullRefund
        );

        uint256 investedTokensToRefundScaled = _updateRefundStateAndCalculateRefundAmount(
            idoId,
            tokensToRefund,
            percentToReturn,
            _calculateBonusAmount(user),
            pricing.initialPriceUsdt
        );

        IERC20(user.investedToken).safeTransfer(msg.sender, investedTokensToRefundScaled);

        emit Refund(idoId, msg.sender, tokensToRefund, investedTokensToRefundScaled);
    }

    /// @inheritdoc IReservesManager
    function withdrawStablecoins(
        uint256 idoId,
        address token,
        uint256 amount
    ) external override onlyReservesAdmin {

        _withdrawStablecoins(
            idoId,
            token,
            amount,
            totalRaisedInToken[idoId][token],
            totalRefundedInToken[idoId][token],
            totalClaimedTokens[idoId],
            idos[idoId].info.totalAllocated,
            idoRefundInfo[idoId].totalRefunded + idoRefundInfo[idoId].refundedBonus
        );
    }

    /// @inheritdoc IReservesManager
    function withdrawUnsoldTokens(uint256 idoId) external override onlyReservesAdmin {
        IDOInfo memory info = idos[idoId].info;
        IDOSchedules memory schedules = idoSchedules[idoId];

        _withdrawUnsoldTokens(
            idoId,
            info.tokenAddress,
            info.totalAllocation,
            info.totalAllocated,
            schedules.idoEndTime
        );
    }

    /// @inheritdoc IReservesManager
    function withdrawRefundedTokens(uint256 idoId) external override onlyReservesAdmin {
        IDOInfo memory info = idos[idoId].info;
        IDORefundInfo memory refundInfo = idoRefundInfo[idoId];

        _withdrawRefundedTokens(
            idoId,
            info.tokenAddress,
            refundInfo.totalRefunded,
            refundInfo.refundedBonus
        );
    }

    /// @inheritdoc IReservesManager
    function withdrawPenaltyFees(uint256 idoId, address stablecoin) external override onlyReservesAdmin {
        _withdrawPenaltyFees(
            idoId,
            stablecoin,
            penaltyFeesCollected[idoId][stablecoin]
        );
    }

    /*
        SETTERS
        ________________________________________________________________
    */

    function setKYCRegistry(
        address _kyc
    ) external override onlyOwner {
        _setKYCRegistry(_kyc);
        emit KYCRegistrySet(_kyc);
    }

    function setAdminManager (
        address _adminManager
    ) external override onlyOwner {
        _setAdminManager(_adminManager);
        emit AdminManagerSet(_adminManager);
    }

    /// @inheritdoc IIDOManager
    function setClaimStartTime(
        uint256 idoId,
        uint64 _claimStartTime
    ) external onlyAdmin {
        idoSchedules[idoId].claimStartTime = _claimStartTime;
        emit ClaimStartTimeSet(idoId, _claimStartTime);
    }

    /// @inheritdoc IIDOManager
    function setTgeTime(
        uint256 idoId,
        uint64 _tgeTime
    ) external onlyAdmin {
        idoSchedules[idoId].tgeTime = _tgeTime;
        emit TgeTimeSet(idoId, _tgeTime);
    }

    /// @inheritdoc IIDOManager
    function setIdoTime(
        uint256 idoId,
        uint64 _idoStartTime,
        uint64 _idoEndTime
    ) external onlyAdmin {
        idoSchedules[idoId].idoStartTime = _idoStartTime;
        idoSchedules[idoId].idoEndTime = _idoEndTime;
        emit IdoTimeSet(idoId, _idoStartTime, _idoEndTime);
    }

    /// @inheritdoc IIDOManager
    function setTokenAddress(
        uint256 idoId,
        address _address
    ) external onlyAdmin {
        IDO storage ido = idos[idoId];
        ido.info.tokenAddress = _address;
        emit TokenAddressSet(idoId, _address);
    }

    /// @inheritdoc IIDOManager
    function setStaticPrice(address token, uint256 price) external onlyAdmin {
        staticPrices[token] = price;
        emit StaticPriceSet(token, price);
    }

    /// @inheritdoc IIDOManager
    function setTwapPriceUsdt(
        uint256 idoId,
        uint256 twapPriceUsdt
    ) external onlyAdmin {
        idoPricing[idoId].twapPriceUsdt = twapPriceUsdt;
        emit TwapSet(idoId, twapPriceUsdt);
    }


    /*
        VIEW FUNCTIONS
        ________________________________________________________________
    */

    /// @inheritdoc IIDOManager
    function getIDOTotalAllocationUSD(uint256 idoId) external view returns (uint256) {
        IDOInfo memory info = idos[idoId].info;
        IDOPricing memory pricing = idoPricing[idoId];

        return _convertToUSDT(info.totalAllocation, pricing.initialPriceUsdt);
    }

    /// @inheritdoc IIDOManager
    function getIDOTotalAllocationByUserUSD(uint256 idoId) external view returns (uint256) {
        IDOInfo memory info = idos[idoId].info;
        IDOPricing memory pricing = idoPricing[idoId];

        return _convertToUSDT(info.totalAllocationByUser, pricing.initialPriceUsdt);
    }

    /// @inheritdoc IIDOManager
    function isRefundAvailable(uint256 idoId, bool fullRefund) external view returns (bool) {
        return _isRefundAllowed(idoSchedules[idoId], idoRefundInfo[idoId], idoPricing[idoId], userInfo[idoId][msg.sender], fullRefund);
    }

    /// @inheritdoc IIDOManager
    function getTokensAvailableToClaim(
        uint256 idoId,
        address user
    ) external view returns (uint256) {
        (uint256 tokens, uint256 bonus) = _getTokensAvailableToClaim(idoSchedules[idoId], userInfo[idoId][user]);
        return tokens + bonus;
    }

    /// @inheritdoc IIDOManager
    function getTokensAvailableToRefund(
        uint256 idoId,
        address user,
        bool fullRefund
    ) external view returns (uint256 amount) {
        return _getTokensAvailableToRefund(
            idoSchedules[idoId],
            idoRefundInfo[idoId],
            idoPricing[idoId],
            userInfo[idoId][user],
            fullRefund
        );
    }

    /// @inheritdoc IIDOManager
    function getTokensAvailableToRefundWithPenalty(
        uint256 idoId,
        address user,
        bool fullRefund
    ) external view returns (uint256 totalRefundAmount, uint256 refundPercentAfterPenalty) {
        IDOSchedules memory schedules = idoSchedules[idoId];
        IDORefundInfo memory refundInfo = idoRefundInfo[idoId];
        IDOPricing memory pricing = idoPricing[idoId];
        UserInfo memory userInfoLocal = userInfo[idoId][user];

        totalRefundAmount = _getTokensAvailableToRefund(schedules, refundInfo, pricing, userInfoLocal, fullRefund);
        refundPercentAfterPenalty = _getRefundPercentAfterPenalty(schedules, refundInfo, pricing, userInfoLocal, fullRefund);
    }

    /// @inheritdoc IReservesManager
    function getWithdrawableAmount(
        uint256 idoId,
        address token
    ) external view override returns (uint256) {
        return _getWithdrawableAmount(
            idoId,
            token,
            totalRaisedInToken[idoId][token],
            totalRefundedInToken[idoId][token],
            totalClaimedTokens[idoId],
            idos[idoId].info.totalAllocated,
            idoRefundInfo[idoId].totalRefunded + idoRefundInfo[idoId].refundedBonus
        );
    }

    /// @inheritdoc IIDOManager
    function currentPhase(uint256 idoId) external view returns (Phase) {
        IDO memory ido = idos[idoId];
        return _currentPhase(ido);
    }

    /// @inheritdoc IIDOManager
    function getUnlockedPercent(uint256 idoId) public view returns (uint256) {
        return _getUnlockedPercent(idoSchedules[idoId]);
    }

    /// @inheritdoc IIDOManager
    function getUserInfo(
        uint256 idoId,
        address userAddr
    ) external view returns (
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

    /*
        INTERNAL FUNCTIONS
        ________________________________________________________________
    */

    function _validateIDOInputs(
        IDOInput memory idoInput,
        IDOInfo memory _idoInputInfo,
        IDOSchedules memory _idoInputSchedules
    ) internal pure {
        require(_idoInputSchedules.idoStartTime < _idoInputSchedules.idoEndTime, InvalidIDOTimeRange());
        require(_idoInputInfo.totalAllocationByUser > 0, InvalidUserAllocation());
        require(_idoInputInfo.totalAllocation > 0, InvalidTotalAllocation());
        require(idoInput.initialPriceUsdt > 0, InvalidPrice());

        require(_idoInputSchedules.vestingDuration > 0, InvalidVestingDuration());
        require(_idoInputSchedules.unlockInterval > 0, InvalidUnlockInterval());
        require(_idoInputSchedules.unlockInterval <= _idoInputSchedules.vestingDuration, UnlockIntervalTooLarge());
        require(_idoInputSchedules.tgeUnlockPercent <= HUNDRED_PERCENT, InvalidTGEUnlockPercent());
    }

    function _getTokensAvailableToClaim(
        IDOSchedules memory schedules,
        UserInfo memory user
    ) internal view returns (uint256, uint256) {
        uint256 unlockedPercent = _getUnlockedPercent(schedules);
        require(unlockedPercent > 0, TokensLocked());

        uint256 unlockedWithoutBonus = (user.allocatedTokens - user.allocatedBonus).mulDiv(unlockedPercent, HUNDRED_PERCENT);
        uint256 unlockedBonus = user.allocatedBonus.mulDiv(unlockedPercent, HUNDRED_PERCENT);
        uint256 claimedTokensWOBonus = user.claimedTokens - user.claimedBonus;

        return (
            unlockedWithoutBonus > claimedTokensWOBonus + user.refundedTokens ? unlockedWithoutBonus - claimedTokensWOBonus - user.refundedTokens : 0,
            unlockedBonus > user.claimedBonus + user.refundedBonus ? unlockedBonus - user.claimedBonus - user.refundedBonus : 0
        );
    }

    function _getTokensAvailableToRefund(
        IDOSchedules memory schedules,
        IDORefundInfo memory refundInfo,
        IDOPricing memory pricing,
        UserInfo memory user,
        bool fullRefund
    ) internal view returns (uint256 tokensToRefund) {
        if (!_isRefundAllowed(schedules, refundInfo, pricing, user, fullRefund)) {
            return 0;
        }

        uint256 totalToRefund;
        if (fullRefund && !refundInfo.refundPolicy.isRefundUnlockedPartOnly) {
            totalToRefund = user.allocatedTokens - user.allocatedBonus;
        } else {
            uint256 unlockedPercent = _getUnlockedPercent(schedules);
            totalToRefund = (user.allocatedTokens - user.allocatedBonus).mulDiv(unlockedPercent, HUNDRED_PERCENT);
        }

        uint tokensTaken = user.refundedTokens + user.claimedTokens;
        return (totalToRefund > tokensTaken ? totalToRefund - tokensTaken : 0);
    }

    function _getRefundPercentAfterPenalty(
        IDOSchedules memory schedules, 
        IDORefundInfo memory refundInfo, 
        IDOPricing memory pricing,
        UserInfo memory user,
        bool fullRefund
    ) internal view returns (uint256 refundPercentAfterPenalty) {
        if (!_isRefundAllowed(schedules, refundInfo, pricing, user, fullRefund)) {
            return 0;
        }

        uint256 penalty;

        if (_isTWAPWindowFinished(schedules)
            && !_isFullRefundWindowFinished(schedules, refundInfo.refundPolicy)
            && _isTWAPUndervalued(pricing)
        ) {
            penalty = 0;
        } else if (fullRefund) {
            penalty = schedules.tgeTime == 0 || !_isTGEStarted(schedules) ? 
                refundInfo.refundPenalties.fullRefundPenaltyBeforeTge : 
                refundInfo.refundPenalties.fullRefundPenalty;
        } else {
            penalty = refundInfo.refundPenalties.refundPenalty;
        }

        return HUNDRED_PERCENT - penalty;
    }

    function _calculateAmountInUSD(
        address tokenIn,
        uint256 amount
    ) internal view returns (uint256 amountInUSD) {
        uint256 staticPrice = staticPrices[tokenIn];

        require(staticPrice > 0, StaticPriceNotSet());

        ERC20 _tokenIn = ERC20(tokenIn);
        uint256 normalizedAmount = amount.mulDiv(DECIMALS, 10 ** _tokenIn.decimals());
        return _convertToUSDT(normalizedAmount, staticPrice);
    }

    function _calculateTokensBought(
        uint256 amountInUSD,
        uint256 bonusPercent,
        uint256 initialPriceUsdt
    ) internal pure returns (uint256 tokensBought) {
        uint256 bonusesMultiplier = bonusPercent + HUNDRED_PERCENT;
        return _convertFromUSDT(amountInUSD, initialPriceUsdt)
            .mulDiv(bonusesMultiplier, HUNDRED_PERCENT);
    }

    function _saveUserInvestment(
        uint256 idoId,
        uint256 amount,
        uint256 amountInUSD,
        address tokenIn,
        uint256 tokensBought,
        uint256 tokensBonus,
        Phase phaseNow
    ) internal {
        UserInfo storage user = userInfo[idoId][msg.sender];

        user.investedUsdt += amountInUSD;
        user.investedTokenAmount += amount;
        user.investedTime = uint64(block.timestamp);
        user.investedPhase = phaseNow;
        user.investedToken = tokenIn;
        user.allocatedTokens += tokensBought;
        user.allocatedBonus += tokensBonus;
    }

    function _validateInvestmentState(
        IDO memory ido,
        IDOSchedules memory schedules,
        UserInfo memory user,
        IDOPricing memory pricing
    ) internal view {
        require(ido.info.totalAllocated < ido.info.totalAllocation && block.timestamp <= schedules.idoEndTime, IDOEnded());
        require(block.timestamp >= schedules.idoStartTime, IDONotStarted());
        require(pricing.initialPriceUsdt > 0, InvalidPrice());
        require(user.investedToken == address(0), AlreadyInvested());
    }

    function _checkAllocationLimits(
        uint256 tokensBought,
        IDO memory ido,
        UserInfo memory user,
        IDORefundInfo memory refundInfo
    ) internal pure {
        require(tokensBought + user.allocatedTokens - user.refundedTokens - user.refundedBonus <= ido.info.totalAllocationByUser, ExceedsUserAllocation());
        require(tokensBought + ido.info.totalAllocated - refundInfo.totalRefunded - refundInfo.refundedBonus <= ido.info.totalAllocation, ExceedsTotalAllocation());
    }

    function _recordRefundPenalties(
        uint256 idoId,
        address token,
        uint256 fullRefundUsdt,
        uint256 refundedUsdt,
        address investedToken
    ) internal {
        uint256 penaltyUsdt = fullRefundUsdt - refundedUsdt;
        uint256 penaltyInInvestedToken = _convertFromUSDT(penaltyUsdt, staticPrices[investedToken]);
        uint256 penaltyScaled = penaltyInInvestedToken.mulDiv(10 ** ERC20(token).decimals(), DECIMALS);
        penaltyFeesCollected[idoId][investedToken] += penaltyScaled;
    }

    function _calculateBonusAmount(UserInfo memory user) internal pure returns (uint256) {
        uint256 bonusToSub = user.allocatedBonus - user.refundedBonus - user.claimedBonus;
        return bonusToSub;
    }

    function _updateRefundStateAndCalculateRefundAmount(
        uint256 idoId,
        uint256 tokensToRefund,
        uint256 percentToReturn,
        uint256 bonusToSub,
        uint256 initialPriceUsdt
    ) internal returns (uint256 investedTokensToRefundScaled) {
        UserInfo storage userStorage = userInfo[idoId][msg.sender];
        UserInfo memory user = userInfo[idoId][msg.sender];

        userStorage.refundedBonus += bonusToSub;
        userStorage.refundedTokens += tokensToRefund;

        idoRefundInfo[idoId].totalRefunded += tokensToRefund;
        idoRefundInfo[idoId].refundedBonus += bonusToSub;

        uint256 fullRefundUsdt = _convertToUSDT(tokensToRefund, initialPriceUsdt);
        uint256 refundedUsdt = fullRefundUsdt.mulDiv(percentToReturn, HUNDRED_PERCENT);

        idoRefundInfo[idoId].totalRefundedUSDT += refundedUsdt;
        userStorage.refundedUsdt += refundedUsdt;

        uint256 investedTokensToRefund = _convertFromUSDT(refundedUsdt, staticPrices[user.investedToken]);
        ERC20 token = ERC20(user.investedToken);
        investedTokensToRefundScaled = investedTokensToRefund.mulDiv(10 ** token.decimals(), DECIMALS);

        require(user.investedTokenAmountRefunded + investedTokensToRefundScaled <= user.investedTokenAmount, RefundExceedsInvested());

        userStorage.investedTokenAmountRefunded += investedTokensToRefundScaled;

        // Track stablecoin refunded for this IDO
        totalRefundedInToken[idoId][user.investedToken] += investedTokensToRefundScaled;

        // Track penalty fees collected (difference between full refund and actual refund)
        if (percentToReturn < HUNDRED_PERCENT) {
            _recordRefundPenalties(idoId, user.investedToken, fullRefundUsdt, refundedUsdt, user.investedToken);
        }
    }

    function _currentPhase(IDO memory ido) internal pure returns (Phase) {
        require(ido.info.totalAllocation > 0, InvalidTotalAllocationForPhase());

        uint256 oneThird = ido.info.totalAllocation / 3;

        if (ido.info.totalAllocated < oneThird) {
            return Phase.Phase1;
        } else if (ido.info.totalAllocated < 2 * oneThird) {
            return Phase.Phase2;
        } else {
            return Phase.Phase3;
        }
    }

    function _getPhaseBonus(IDO memory ido) internal pure returns (uint256, Phase) {
        Phase phase = _currentPhase(ido);
        if (phase == Phase.Phase1) return (ido.bonuses.phase1BonusPercent, phase);
        if (phase == Phase.Phase2) return (ido.bonuses.phase2BonusPercent, phase);
        return (ido.bonuses.phase3BonusPercent, phase);
    }

    function _getUnlockedPercent(
        IDOSchedules memory schedules
    ) internal view returns (uint256) {
        if (schedules.tgeTime == 0 || !_isTGEStarted(schedules)) {
            return 0;
        }

        if (!_isCliffFinished(schedules)) {
            return schedules.tgeUnlockPercent;
        }

        uint256 vestingEndTime = schedules.tgeTime + schedules.cliffDuration + schedules.vestingDuration;

        if (block.timestamp > vestingEndTime) {
            return HUNDRED_PERCENT;
        }

        uint256 vestingTime = block.timestamp - schedules.tgeTime - schedules.cliffDuration;
        uint256 intervalsCompleted = vestingTime / schedules.unlockInterval;
        uint256 totalIntervals = _getNumberOfVestingIntervals(schedules);

        uint256 vestingPercent = intervalsCompleted.mulDiv(
            HUNDRED_PERCENT - schedules.tgeUnlockPercent,
            totalIntervals
        );

        return schedules.tgeUnlockPercent + vestingPercent;
    }

    function _getNumberOfVestingIntervals(
        IDOSchedules memory schedules
    ) internal pure returns (uint256) {
        uint256 totalIntervals = schedules.vestingDuration / schedules.unlockInterval;

        if (schedules.vestingDuration % schedules.unlockInterval != 0) {
            totalIntervals += 1;
        }

        return totalIntervals;
    }

    function _isRefundAllowed(
        IDOSchedules memory schedules, 
        IDORefundInfo memory refundInfo, 
        IDOPricing memory pricing, 
        UserInfo memory user, 
        bool fullRefund
    ) internal view returns (bool) {
        
        if (!_isTGEStarted(schedules)) {
            return _isRefundBeforeTGEAllowed(fullRefund, refundInfo);
        }
        if (_isTWAPWindowFinished(schedules) &&
            !_isFullRefundWindowFinished(schedules, refundInfo.refundPolicy)) 
        {
            return _isTWAPUndervalued(pricing) && fullRefund;
        }
        if (!_isCliffFinished(schedules)) {
            return _isCliffRefundAllowed(fullRefund, refundInfo);
        }
        if (_isCliffFinished(schedules)) {
            return _isRefundInVestingAllowed(fullRefund, refundInfo);
        }
        if (!refundInfo.refundPolicy.isRefundIfClaimedAllowed && user.claimed) {
            return false;
        }

        return true;
    }

    function _convertToUSDT(
        uint256 amount,
        uint256 priceOfToken
    ) internal pure returns (uint256 amountInUSDT) {
        require(priceOfToken > 0, InvalidPrice());
        amountInUSDT = amount.mulDiv(priceOfToken, PRICE_DECIMALS);
    }

    function _convertFromUSDT(
        uint256 amountUSDT,
        uint256 priceOfToken
    ) internal pure returns (uint256 amountInToken) {
        require(priceOfToken > 0, InvalidPrice());
        amountInToken = amountUSDT.mulDiv(PRICE_DECIMALS, priceOfToken);
    }

    function _isTGEStarted(IDOSchedules memory _idoSchedules) internal view returns (bool) {
        uint64 tgeTime = _idoSchedules.tgeTime;
        return tgeTime > 0 && block.timestamp >= tgeTime;
    }

    function _isCliffFinished(IDOSchedules memory _idoSchedules) internal view returns (bool) {
        uint64 tgeTime = _idoSchedules.tgeTime;
        return tgeTime > 0 && block.timestamp >= tgeTime + _idoSchedules.cliffDuration;
    }

    function _isTWAPWindowFinished(IDOSchedules memory _idoSchedules) internal view returns (bool) {
        uint64 tgeTime = _idoSchedules.tgeTime;
        return tgeTime > 0 && block.timestamp >= tgeTime + _idoSchedules.twapCalculationWindowHours * 1 hours;
    }

    function _isFullRefundWindowFinished(IDOSchedules memory _idoSchedules, RefundPolicy memory _refundPolicy) internal view returns (bool) {
        uint64 tgeTime = _idoSchedules.tgeTime;
        return tgeTime > 0 && block.timestamp >= tgeTime + _idoSchedules.twapCalculationWindowHours * 1 hours + _refundPolicy.fullRefundDuration;
    }

    function _isTWAPUndervalued(IDOPricing memory _idoPricing) internal pure returns (bool) {
        return _idoPricing.twapPriceUsdt > 0 && _idoPricing.twapPriceUsdt <= _idoPricing.initialPriceUsdt;
    }

    function _isRefundBeforeTGEAllowed(bool fullRefund, IDORefundInfo memory refundInfo) internal pure returns (bool) {
        if (fullRefund) {
            return refundInfo.refundPolicy.isFullRefundBeforeTGEAllowed;
        } else {
            return false;
        }
    }

    function _isCliffRefundAllowed(bool fullRefund, IDORefundInfo memory refundInfo) internal pure returns (bool) {
        if (fullRefund) {
            return refundInfo.refundPolicy.isFullRefundInCliffAllowed;
        } else {
            return refundInfo.refundPolicy.isPartialRefundInCliffAllowed;
        }
    }

    function _isRefundInVestingAllowed(bool fullRefund, IDORefundInfo memory refundInfo) internal pure returns (bool) {
        if (fullRefund) {
            return refundInfo.refundPolicy.isFullRefundInVestingAllowed;
        } else {
            return refundInfo.refundPolicy.isPartialRefundInVestingAllowed;
        }
    }
}
