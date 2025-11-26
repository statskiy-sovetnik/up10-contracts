// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./WithAdminManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AdminManager is IAdminManager, Ownable {
    mapping(address => bool) public isAdmin;

    constructor(address _initialOwner, address _initialAdmin) Ownable(_initialOwner) {
        isAdmin[_initialAdmin] = true;
    }

    /// @inheritdoc IAdminManager
    function addAdmin(address _admin) external onlyOwner {
        isAdmin[_admin] = true;
    }

    /// @inheritdoc IAdminManager
    function removeAdmin(address _admin) external onlyOwner {
        isAdmin[_admin] = false;
    }

    /// @inheritdoc IAdminManager
    function isAdminAddress(address _addr) external view returns (bool) {
        return isAdmin[_addr];
    }

    function _setAdmin(address _admin, bool _status) internal {
        isAdmin[_admin] = _status;
    }
}
