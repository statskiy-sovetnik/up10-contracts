// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IKYCRegistry {
    /// @notice Checks if a user has completed KYC verification
    /// @dev Returns the KYC status from the isVerified mapping
    /// @param user The address of the user to check
    /// @return True if the user is KYC verified, false otherwise
    function isKYCed(address user) external view returns (bool);

    /// @notice Verifies a user's KYC status
    /// @dev Only callable by owner. Sets the user's verification status to true
    /// @param user The address of the user to verify
    function verify(address user) external;

    /// @notice Revokes a user's KYC verification
    /// @dev Only callable by owner. Sets the user's verification status to false
    /// @param user The address of the user to revoke
    function revoke(address user) external;
}