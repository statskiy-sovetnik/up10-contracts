// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IReservesManager.sol";
import "./Errors.sol";

abstract contract ReservesManager is IReservesManager {
    using Math for uint256;
    using SafeERC20 for IERC20;

    address public reservesAdmin;

    // Stablecoin addresses
    address public immutable USDT;
    address public immutable USDC;
    address public immutable FLX;

    // Track stablecoins already withdrawn by reserves admin per IDO per token
    mapping(uint256 => mapping(address => uint256)) public stablecoinsWithdrawnInToken;

    // Track penalty fees collected per IDO per stablecoin
    mapping(uint256 => mapping(address => uint256)) public penaltyFeesCollected;

    // Track unsold tokens withdrawn per IDO
    mapping(uint256 => uint256) public unsoldTokensWithdrawn;

    // Track refunded tokens withdrawn per IDO
    mapping(uint256 => uint256) public refundedTokensWithdrawn;

    // Track penalty fees withdrawn per IDO per stablecoin
    mapping(uint256 => mapping(address => uint256)) public penaltyFeesWithdrawn;

    uint32 private constant HUNDRED_PERCENT = 10_000_000;

    event ReservesAdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event AdminWithdrawal(uint256 indexed idoId, address indexed token, uint256 amount);
    event UnsoldTokensWithdrawn(uint256 indexed idoId, address indexed token, uint256 amount);
    event RefundedTokensWithdrawn(uint256 indexed idoId, address indexed token, uint256 amount);
    event PenaltyFeesWithdrawn(uint256 indexed idoId, address indexed stablecoin, uint256 amount);

    modifier onlyReservesAdmin() {
        require(msg.sender == reservesAdmin, OnlyReservesAdmin());
        _;
    }

    constructor(address _initialAdmin, address _usdt, address _usdc, address _flx) {
        require(_initialAdmin != address(0), InvalidZeroAddress());
        require(_usdt != address(0) && _usdc != address(0) && _flx != address(0), InvalidTokenAddress());

        reservesAdmin = _initialAdmin;
        USDT = _usdt;
        USDC = _usdc;
        FLX = _flx;
    }

    /// @inheritdoc IReservesManager
    function getWithdrawableAmount(
        uint256 idoId,
        address token
    ) external view virtual returns (uint256);

    /// @inheritdoc IReservesManager
    function withdrawStablecoins(
        uint256 idoId,
        address token,
        uint256 amount
    ) external virtual;

    /// @inheritdoc IReservesManager
    function withdrawUnsoldTokens(uint256 idoId) external virtual;

    /// @inheritdoc IReservesManager
    function withdrawRefundedTokens(uint256 idoId) external virtual;

    /// @inheritdoc IReservesManager
    function withdrawPenaltyFees(uint256 idoId, address stablecoin) external virtual;

    /// @inheritdoc IReservesManager
    function changeReservesAdmin(
        address newAdmin
    ) external onlyReservesAdmin {
        _setReservesAdmin(newAdmin);
    }

    /// @inheritdoc IReservesManager
    function isStablecoin(address token) public view returns (bool) {
        return token == USDT || token == USDC || token == FLX;
    }

    /**
     * @notice Internal function to calculate withdrawable amount
     * @dev All logic and calculation happens here. Values are passed from storage of IDOManager
     * @param idoId The IDO identifier
     * @param token The stablecoin address
     * @param totalRaised Total stablecoins raised for this IDO in this token
     * @param totalRefunded Total stablecoins refunded for this IDO in this token
     * @param totalClaimed Total tokens claimed by users for this IDO
     * @param totalAllocated Total tokens allocated for this IDO
     * @param totalRefundedTokens Total tokens refunded for this IDO
     * @return withdrawable The amount admin can withdraw
     */
    function _getWithdrawableAmount(
        uint256 idoId,
        address token,
        uint256 totalRaised,
        uint256 totalRefunded,
        uint256 totalClaimed,
        uint256 totalAllocated,
        uint256 totalRefundedTokens
    ) internal view returns (uint256 withdrawable) {
        require(isStablecoin(token), NotAStablecoin());

        uint256 netRaised = totalRaised - totalRefunded;
        uint256 netAllocated = totalAllocated > totalRefundedTokens ? totalAllocated - totalRefundedTokens : 0;
        if (netAllocated == 0) return 0;

        uint256 claimedPercent = totalClaimed.mulDiv(HUNDRED_PERCENT, netAllocated);
        uint256 unlockedAmount = netRaised.mulDiv(claimedPercent, HUNDRED_PERCENT);

        uint256 withdrawn = stablecoinsWithdrawnInToken[idoId][token];

        return unlockedAmount > withdrawn ? unlockedAmount - withdrawn : 0;
    }

    /**
     * @notice Internal function to execute stablecoin withdrawal
     * @dev All logic happens here. Values are passed from storage of IDOManager
     * @param idoId The IDO identifier
     * @param token The stablecoin address
     * @param amount The amount to withdraw
     * @param totalRaised Total stablecoins raised for this IDO in this token
     * @param totalRefunded Total stablecoins refunded for this IDO in this token
     * @param totalClaimed Total tokens claimed by users for this IDO
     * @param totalAllocated Total tokens allocated for this IDO
     * @param totalRefundedTokens Total tokens refunded for this IDO
     */
    function _withdrawStablecoins(
        uint256 idoId,
        address token,
        uint256 amount,
        uint256 totalRaised,
        uint256 totalRefunded,
        uint256 totalClaimed,
        uint256 totalAllocated,
        uint256 totalRefundedTokens
    ) internal {
        require(amount > 0, InvalidAmount());
        require(isStablecoin(token), NotAStablecoin());

        uint256 withdrawable = _getWithdrawableAmount(
            idoId,
            token,
            totalRaised,
            totalRefunded,
            totalClaimed,
            totalAllocated,
            totalRefundedTokens
        );

        require(amount <= withdrawable, ExceedsWithdrawableAmount());

        stablecoinsWithdrawnInToken[idoId][token] += amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit AdminWithdrawal(idoId, token, amount);
    }

    /**
     * @notice Internal function to withdraw unsold tokens
     * @dev All logic happens here. Values are passed from storage of IDOManager
     * @param idoId The IDO identifier
     * @param tokenAddress The project token address
     * @param totalAllocation Total tokens allocated for the IDO
     * @param totalAllocated Total tokens actually sold/allocated to users
     * @param idoEndTime When the IDO ends
     */
    function _withdrawUnsoldTokens(
        uint256 idoId,
        address tokenAddress,
        uint256 totalAllocation,
        uint256 totalAllocated,
        uint64 idoEndTime
    ) internal {
        // Check IDO has ended
        require(block.timestamp > idoEndTime, IDONotEnded());

        // Check token address is set
        require(tokenAddress != address(0), InvalidZeroAddress());

        // Calculate unsold tokens
        uint256 unsoldTokens = totalAllocation - totalAllocated;
        require(unsoldTokens > 0, NoUnsoldTokens());

        // Check we haven't already withdrawn these tokens
        require(unsoldTokensWithdrawn[idoId] == 0, InsufficientTokensAvailable());

        // Mark as withdrawn
        unsoldTokensWithdrawn[idoId] = unsoldTokens;

        // Transfer tokens to reserves admin
        IERC20(tokenAddress).safeTransfer(msg.sender, unsoldTokens);

        emit UnsoldTokensWithdrawn(idoId, tokenAddress, unsoldTokens);
    }

    /**
     * @notice Internal function to withdraw refunded tokens
     * @dev All logic happens here. Values are passed from storage of IDOManager
     * @param idoId The IDO identifier
     * @param tokenAddress The project token address
     * @param totalRefunded Total regular tokens refunded
     * @param refundedBonus Total bonus tokens refunded
     */
    function _withdrawRefundedTokens(
        uint256 idoId,
        address tokenAddress,
        uint256 totalRefunded,
        uint256 refundedBonus
    ) internal {
        // Check token address is set
        require(tokenAddress != address(0), InvalidZeroAddress());

        // Calculate refunded tokens available
        uint256 refundedTokens = totalRefunded + refundedBonus;
        require(refundedTokens > 0, NoRefundedTokens());

        // Calculate how much we can still withdraw
        uint256 alreadyWithdrawn = refundedTokensWithdrawn[idoId];
        require(refundedTokens > alreadyWithdrawn, NoRefundedTokens());

        uint256 availableToWithdraw = refundedTokens - alreadyWithdrawn;

        // Mark as withdrawn
        refundedTokensWithdrawn[idoId] = refundedTokens;

        // Transfer tokens to reserves admin
        IERC20(tokenAddress).safeTransfer(msg.sender, availableToWithdraw);

        emit RefundedTokensWithdrawn(idoId, tokenAddress, availableToWithdraw);
    }

    /**
     * @notice Internal function to withdraw penalty fees
     * @dev All logic happens here. Values are passed from storage of IDOManager
     * @param idoId The IDO identifier
     * @param stablecoin The stablecoin address
     * @param penaltyFeesCollectedAmount Total penalty fees collected for this IDO in this stablecoin
     */
    function _withdrawPenaltyFees(
        uint256 idoId,
        address stablecoin,
        uint256 penaltyFeesCollectedAmount
    ) internal {
        // Validate stablecoin
        require(isStablecoin(stablecoin), NotAStablecoin());

        // Check penalty fees collected
        require(penaltyFeesCollectedAmount > 0, NoPenaltyFees());

        // Calculate how much we can still withdraw
        uint256 alreadyWithdrawn = penaltyFeesWithdrawn[idoId][stablecoin];
        require(penaltyFeesCollectedAmount > alreadyWithdrawn, NoPenaltyFees());

        uint256 availableToWithdraw = penaltyFeesCollectedAmount - alreadyWithdrawn;

        // Mark as withdrawn
        penaltyFeesWithdrawn[idoId][stablecoin] = penaltyFeesCollectedAmount;

        // Transfer stablecoins to reserves admin
        IERC20(stablecoin).safeTransfer(msg.sender, availableToWithdraw);

        emit PenaltyFeesWithdrawn(idoId, stablecoin, availableToWithdraw);
    }

    function _setReservesAdmin(address _newAdmin) internal {
        require(_newAdmin != address(0), InvalidZeroAddress());
        address oldAdmin = reservesAdmin;
        reservesAdmin = _newAdmin;
        emit ReservesAdminChanged(oldAdmin, _newAdmin);
    }
}
