// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {
    EmptyProofLength,
    UnknownVerifierType,
    MockVerifierNotSupported,
    EmptyPublicInputsLength
} from "../../common/L1ContractErrors.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";
import {
    ZKSYNC_OS_MOCK_VERIFICATION_TYPE,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE,
    ZKSYNC_OS_PROOF_METADATA_LENGTH
} from "../../common/Config.sol";

/// @title ZKsync OS Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps the ZKsync OS PLONK verifier and supports mock verification on testnets.
/// It reuses the same interface as on the original `Verifier` contract, while abusing one of the fields
/// (`_recursiveAggregationInput`) for proof verification type.
contract ZKsyncOSVerifier is IVerifier, IZKsyncOSVerifier {
    /// @notice The PLONK verifier contract.
    IVerifier public immutable PLONK_VERIFIER;

    /// @param _plonkVerifier The address of the PLONK verifier contract.
    constructor(IVerifier _plonkVerifier) {
        PLONK_VERIFIER = _plonkVerifier;
    }

    /// @notice Verifies a ZKsync OS PLONK proof or delegates to the testnet mock path.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The zk-SNARK proof itself.
    /// @dev  The first element of the `_proof` determines the verifier type.
    ///     - 2 indicates the ZKsync OS Plonk verifier should be used.
    ///     - 3 indicates the mock verifier (skipping proof verification) should be used.
    /// @return Returns `true` if the proof verification succeeds, otherwise throws an error.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        // Ensure the proof has a valid length (at least one element
        // for the proof system differentiator).
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }

        // Ensure public inputs are not empty for clarity.
        if (_publicInputs.length == 0) {
            revert EmptyPublicInputsLength();
        }

        // The first element of `_proof` determines the verifier type.
        uint256 verifierType = _proof[0];

        if (verifierType == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            uint256[] memory args = new uint256[](1);
            args[0] = computeZKsyncOSHash(_proof[1], _publicInputs);

            return PLONK_VERIFIER.verify(args, _extractZKsyncOSProof(_proof));
        } else if (verifierType == ZKSYNC_OS_MOCK_VERIFICATION_TYPE) {
            uint256[] memory args = new uint256[](1);
            args[0] = computeZKsyncOSHash(_proof[1], _publicInputs);

            return mockVerify(args, _extractZKsyncOSProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @dev Verifies the correctness of public input, doesn't check the validity of proof itself.
    function mockVerify(uint256[] memory, uint256[] memory) public view virtual returns (bool) {
        revert MockVerifierNotSupported();
    }

    /// @inheritdoc IVerifier
    /// @dev Used for backward compatibility with older Verifier implementation. Returns PLONK verification key hash.
    function verificationKeyHash() external view returns (bytes32) {
        return PLONK_VERIFIER.verificationKeyHash();
    }

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys from the selected verifier.
    /// @return The keccak256 hash of the loaded verification keys based on the verifier.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        if (_verifierType == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            return PLONK_VERIFIER.verificationKeyHash();
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    function _extractZKsyncOSProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - ZKSYNC_OS_PROOF_METADATA_LENGTH;

        // Allocate memory for the underlying proof after removing its type and initial hash.
        result = new uint256[](resultLength);

        // Copy elements after the two metadata words.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x40), mul(resultLength, 0x20))
        }
    }

    function computeZKsyncOSHash(
        uint256 _initialHash,
        uint256[] calldata _publicInputs
    ) public pure returns (uint256 result) {
        uint256 publicInputsLength = _publicInputs.length;
        result = _initialHash;

        uint256 i = 0;

        if (result == 0) {
            result = _publicInputs[0];
            i = 1;
        }

        for (; i < publicInputsLength; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _publicInputs[i]))) >> 32;
        }
    }
}
