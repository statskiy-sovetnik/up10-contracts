// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IAdminManager.sol";
import "../Errors.sol";

abstract contract WithAdminManager {
    IAdminManager public adminManager;

    modifier onlyAdmin() {
        require(adminManager.isAdminAddress(msg.sender), CallerNotAdmin());
        _;
    }

    constructor(address _adminManager) {
        _setAdminManager(_adminManager);
    }

    function setAdminManager(
        address _adminManager
    ) external virtual {
        _setAdminManager(_adminManager);
    }

    function _setAdminManager(address _adminManager) internal {
        adminManager = IAdminManager(_adminManager);
    }
}
