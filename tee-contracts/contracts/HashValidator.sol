// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "solady/auth/Ownable.sol";
import {IHashValidator, EmptyArray} from "./interfaces/IHashValidator.sol";

/**
 * @title HashValidator
 * @dev Manages a set of valid hashes with batch operations for efficiency.
 */
contract HashValidator is Ownable, IHashValidator {
    mapping(bytes32 => bool) private validEnclaveHashes;
    mapping(bytes32 => bool) private validEnclaveSigners;
    mapping(bytes32 => bool) private validTD10ReportBodyMrHashes;

    event EnclaveSignersUpdated(bytes32[] signers, bool status);
    event EnclaveHashesUpdated(bytes32[] hashes, bool status);
    event TD10ReportBodyMrHashesUpdated(bytes32[] hashes, bool status);

    constructor(address owner) {
        _initializeOwner(owner);
    }

    /**
     * @notice Adds multiple enclave hashes to the valid list.
     * @param hashes The array of hashes to be marked as valid.
     */
    function addValidEnclaveHashes(bytes32[] calldata hashes) external onlyOwner {
        uint256 length = hashes.length;
        require(length > 0, EmptyArray());

        for (uint256 i = 0; i < length; ++i) {
            bytes32 hash = hashes[i];
            if (!validEnclaveHashes[hash]) {
                validEnclaveHashes[hash] = true;
            }
        }
        emit EnclaveHashesUpdated(hashes, true);
    }

    /**
     * @notice Removes multiple enclave hashes from the valid list.
     * @param hashes The array of hashes to be removed.
     */
    function removeValidEnclaveHashes(bytes32[] calldata hashes) external onlyOwner {
        uint256 length = hashes.length;
        require(length > 0, EmptyArray());

        for (uint256 i = 0; i < length; ++i) {
            bytes32 hash = hashes[i];
            if (validEnclaveHashes[hash]) {
                validEnclaveHashes[hash] = false;
            }
        }
        emit EnclaveHashesUpdated(hashes, false);
    }

    /**
     * @notice Checks if a given enclave hash is in the valid list.
     * @param hash The hash to check.
     * @return isValid True if the hash is in the valid list, false otherwise.
     */
    function isValidEnclaveHash(bytes32 hash) external view returns (bool isValid) {
        return validEnclaveHashes[hash];
    }

    /**
     * @notice Adds multiple enclave signers to the valid list.
     * @param signers The array of signer addresses to be marked as valid.
     */
    function addValidEnclaveSigners(bytes32[] calldata signers) external onlyOwner {
        uint256 length = signers.length;
        require(length > 0, EmptyArray());

        for (uint256 i = 0; i < length; ++i) {
            bytes32 signer = signers[i];
            if (!validEnclaveSigners[signer]) {
                validEnclaveSigners[signer] = true;
            }
        }
        emit EnclaveSignersUpdated(signers, true);
    }

    /**
     * @notice Removes multiple enclave signers from the valid list.
     * @param signers The array of signer addresses to be removed.
     */
    function removeValidEnclaveSigners(bytes32[] calldata signers) external onlyOwner {
        uint256 length = signers.length;
        require(length > 0, EmptyArray());

        for (uint256 i = 0; i < length; ++i) {
            bytes32 signer = signers[i];
            if (validEnclaveSigners[signer]) {
                validEnclaveSigners[signer] = false;
            }
        }
        emit EnclaveSignersUpdated(signers, false);
    }

    /**
     * @notice Checks if a given enclave signer address is in the valid list.
     * @param signer The signer address to check.
     * @return isValid True if the signer is in the valid list, false otherwise.
     */
    function isValidEnclaveSigner(bytes32 signer) external view returns (bool isValid) {
        return validEnclaveSigners[signer];
    }

    /**
     * @notice Adds multiple TD10ReportBody Mr hashes to the valid list.
     * @dev hash = keccak256();
     * @param hashes The array of hashes to be marked as valid.
     */
    function addValidTD10ReportBodyMrHashes(bytes32[] calldata hashes) external onlyOwner {
        uint256 length = hashes.length;
        require(length > 0, EmptyArray());

        for (uint256 i = 0; i < length; ++i) {
            bytes32 hash = hashes[i];
            if (!validTD10ReportBodyMrHashes[hash]) {
                validTD10ReportBodyMrHashes[hash] = true;
            }
        }
        emit TD10ReportBodyMrHashesUpdated(hashes, true);
    }

    /**
     * @notice Removes multiple TD10ReportBody Mr hashes from the valid list.
     * @param hashes The array of hashes to be removed.
     */
    function removeValidTD10ReportBodyMrHashes(bytes32[] calldata hashes) external onlyOwner {
        uint256 length = hashes.length;
        require(length > 0, EmptyArray());

        for (uint256 i = 0; i < length; ++i) {
            bytes32 hash = hashes[i];
            if (validTD10ReportBodyMrHashes[hash]) {
                validTD10ReportBodyMrHashes[hash] = false;
            }
        }
        emit TD10ReportBodyMrHashesUpdated(hashes, false);
    }

    /**
     * @notice Checks if a given TD10ReportBody Mr hash is in the valid list.
     * @param hash The hash to check.
     * @return isValid True if the hash is in the valid list, false otherwise.
     */
    function isValidTD10ReportBodyMrHash(bytes32 hash) external view returns (bool isValid) {
        return validTD10ReportBodyMrHashes[hash];
    }
}
