// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

error EmptyArray();

/**
 * @title IHashValidator
 * @dev Manages a set of valid hashes with batch operations for efficiency.
 */
interface IHashValidator {
    function addValidEnclaveHashes(bytes32[] calldata hashes) external;
    function removeValidEnclaveHashes(bytes32[] calldata hashes) external;
    function isValidEnclaveHash(bytes32 hash) external view returns (bool);
    function addValidTD10ReportBodyMrHashes(bytes32[] calldata hashes) external;
    function removeValidTD10ReportBodyMrHashes(bytes32[] calldata hashes) external;
    function isValidTD10ReportBodyMrHash(bytes32 hash) external view returns (bool);
}