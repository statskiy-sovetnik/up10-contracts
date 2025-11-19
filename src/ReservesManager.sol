// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Errors.sol";

abstract contract ReservesManager {
    using Math for uint256;
    using SafeERC20 for IERC20;

    address public reservesAdmin;

    // Stablecoin addresses
    address public immutable USDT;
    address public immutable USDC;
    address public immutable FLX;

    // Track stablecoins already withdrawn by admin per IDO per token
    mapping(uint256 => mapping(address => uint256)) public adminWithdrawnInToken;

    uint32 private constant HUNDRED_PERCENT = 10_000_000;

    event ReservesAdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event AdminWithdrawal(uint256 indexed idoId, address indexed token, uint256 amount);

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

    /**
     * @notice Abstract function - must be implemented by child contract
     * @dev Child should read storage and pass to _getWithdrawableAmount
     */
    function getWithdrawableAmount(
        uint256 idoId,
        address token
    ) external view virtual returns (uint256);

    /**
     * @notice Abstract function - must be implemented by child contract
     * @dev Child should read storage and call internal functions
     */
    function adminWithdraw(
        uint256 idoId,
        address token,
        uint256 amount
    ) external virtual;

    function changeReservesAdmin(
        address newAdmin
    ) external onlyReservesAdmin {
        _setReservesAdmin(newAdmin);
    }

    /**
     * @notice Checks if a token is one of the accepted stablecoins
     * @param token The token address to check
     * @return bool True if the token is a stablecoin
     */
    function isStablecoin(address token) public view returns (bool) {
        return token == USDT || token == USDC || token == FLX;
    }

    /**
     * @notice Internal function to calculate withdrawable amount
     * @dev All logic and calculation happens here
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

        uint256 withdrawn = adminWithdrawnInToken[idoId][token];

        return unlockedAmount > withdrawn ? unlockedAmount - withdrawn : 0;
    }

    /**
     * @notice Internal function to execute admin withdrawal
     * @dev All validation happens here
     * @param idoId The IDO identifier
     * @param token The stablecoin address
     * @param amount The amount to withdraw
     * @param totalRaised Total stablecoins raised for this IDO in this token
     * @param totalRefunded Total stablecoins refunded for this IDO in this token
     * @param totalClaimed Total tokens claimed by users for this IDO
     * @param totalAllocated Total tokens allocated for this IDO
     * @param totalRefundedTokens Total tokens refunded for this IDO
     */
    function _adminWithdraw(
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

        adminWithdrawnInToken[idoId][token] += amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit AdminWithdrawal(idoId, token, amount);
    }

    function _setReservesAdmin(address _newAdmin) internal {
        require(_newAdmin != address(0), InvalidZeroAddress());
        address oldAdmin = reservesAdmin;
        reservesAdmin = _newAdmin;
        emit ReservesAdminChanged(oldAdmin, _newAdmin);
    }
}
