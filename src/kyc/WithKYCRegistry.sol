// SPDX-License-Identifier: MIT 

interface IKYCRegistry {
    function isKYCed(address user) external view returns (bool);
}

abstract contract WithKYCRegistry {
    IKYCRegistry public kyc;

    modifier onlyKYC() {
        require(kyc.isKYCed(msg.sender), "KYC required");
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