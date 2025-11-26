// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IReservesManager {
    /// @notice Calculates the amount of stablecoins that can be withdrawn by the reserves admin
    /// @dev Amount is proportional to the percentage of tokens claimed by users
    /// @param idoId The identifier of the IDO
    /// @param token The stablecoin address (USDT, USDC, or FLX)
    /// @return The amount of stablecoins available for withdrawal
    function getWithdrawableAmount(
        uint256 idoId,
        address token
    ) external view returns (uint256);

    /// @notice Withdraws stablecoins raised from an IDO proportionally to user claims
    /// @dev Only callable by reserves admin. Amount must not exceed withdrawable amount based on claim progress
    /// @param idoId The identifier of the IDO
    /// @param token The stablecoin address to withdraw
    /// @param amount The amount of stablecoins to withdraw
    function withdrawStablecoins(
        uint256 idoId,
        address token,
        uint256 amount
    ) external;

    /// @notice Withdraws unsold project tokens after the IDO has ended
    /// @dev Only callable by reserves admin. Can only be called once per IDO after IDO end time
    /// @param idoId The identifier of the IDO
    function withdrawUnsoldTokens(uint256 idoId) external;

    /// @notice Withdraws project tokens that were refunded by users
    /// @dev Only callable by reserves admin. Withdraws the difference between total refunded and already withdrawn
    /// @param idoId The identifier of the IDO
    function withdrawRefundedTokens(uint256 idoId) external;

    /// @notice Withdraws penalty fees collected from user refunds
    /// @dev Only callable by reserves admin. Penalty fees are charged when users refund with penalties applied
    /// @param idoId The identifier of the IDO
    /// @param stablecoin The stablecoin address to withdraw penalty fees from
    function withdrawPenaltyFees(uint256 idoId, address stablecoin) external;

    /// @notice Changes the reserves admin address
    /// @dev Only callable by current reserves admin
    /// @param newAdmin The address of the new reserves admin
    function changeReservesAdmin(address newAdmin) external;

    /// @notice Checks if a token is one of the accepted stablecoins
    /// @dev Accepted stablecoins are USDT, USDC, and FLX
    /// @param token The token address to check
    /// @return True if the token is an accepted stablecoin, false otherwise
    function isStablecoin(address token) external view returns (bool);
}
