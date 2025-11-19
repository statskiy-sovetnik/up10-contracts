// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IKYCRegistry {
    function isKYCed(address user) external view returns (bool);

    function verify(address user) external;

    function revoke(address user) external;
}