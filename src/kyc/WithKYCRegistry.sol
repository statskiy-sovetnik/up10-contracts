// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IKYCRegistry.sol";
import "../Errors.sol";

abstract contract WithKYCRegistry {
    IKYCRegistry public kyc;

    modifier onlyKYC() {
        require(kyc.isKYCed(msg.sender), KYCRequired());
        _;
    }

    constructor(address _kyc) {
        _setKYCRegistry(_kyc);
    }

    function setKYCRegistry(address _kyc) external virtual {
        _setKYCRegistry(_kyc);
    }

    function _setKYCRegistry(address _kyc) internal {
        kyc = IKYCRegistry(_kyc);
    }
}