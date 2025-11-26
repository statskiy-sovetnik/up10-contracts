// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAdminManager {
    /// @notice Checks if an address has admin privileges
    /// @dev Returns the admin status from the isAdmin mapping
    /// @param _addr The address to check for admin privileges
    /// @return True if the address is an admin, false otherwise
    function isAdminAddress(address _addr) external view returns (bool);

    /// @notice Grants admin privileges to an address
    /// @dev Only callable by owner. Sets the address's admin status to true
    /// @param _admin The address to grant admin privileges
    function addAdmin(address _admin) external;

    /// @notice Revokes admin privileges from an address
    /// @dev Only callable by owner. Sets the address's admin status to false
    /// @param _admin The address to revoke admin privileges from
    function removeAdmin(address _admin) external;
}