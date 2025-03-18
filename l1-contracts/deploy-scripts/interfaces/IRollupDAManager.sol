// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IRollupDAManager {
    function allowedDAPairs(address l1DAValidator, address l2DAValidator) external view returns (bool);
    function updateDAPair(address l1DAValidator, address l2DAValidator, bool status) external;
    function transferOwnership(address newOwner) external;
}
