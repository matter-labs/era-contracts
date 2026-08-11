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
    ZKSYNC_OS_PROOF_METADATA_LENGTH,
    PUBLIC_INPUT_SHIFT
} from "../../common/Config.sol";

/// @title ZKsync OS Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps the ZKsync OS PLONK verifier and supports mock verification on testnets.
/// It reuses the same interface as the original `Verifier` contract, while using the first element of `_proof`
/// for the proof verification type.
contract ZKsyncOSVerifier is IVerifier, IZKsyncOSVerifier {
    /// @notice The PLONK verifier contract.
    IVerifier public immutable PLONK_VERIFIER;

    /// @param _plonkVerifier The address of the PLONK verifier contract.
    constructor(IVerifier _plonkVerifier) {
        PLONK_VERIFIER = _plonkVerifier;
    }

    /// @notice Verifies a ZKsync OS PLONK proof or delegates to the testnet mock path.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The proof prefixed with the verifier type and initial hash.
    /// @dev  The first element of the `_proof` determines the verifier type.
    ///     - 2 indicates the ZKsync OS Plonk verifier should be used.
    ///     - 3 indicates the mock verifier (skipping proof verification) should be used.
    /// @return Returns `true` if verification succeeds and `false` if the underlying verifier rejects the proof.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        // Ensure the verifier type and initial hash metadata are present.
        if (_proof.length < ZKSYNC_OS_PROOF_METADATA_LENGTH) {
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

    /// @notice Returns the wrapped PLONK verifier's verification key hash for the supported verifier type.
    /// @dev Kept for backward compatibility; only the ZKsync OS PLONK verifier type is supported.
    /// @return The wrapped PLONK verifier's verification key hash.
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
        // The prover hashes the concatenation of all per-batch hashes once. A rolling fold
        // coincides for at most two batches but diverges starting with the third batch.
        if (_initialHash == 0) {
            result = _publicInputs.length == 1
                ? _publicInputs[0]
                : uint256(keccak256(abi.encodePacked(_publicInputs)));
        } else {
            result = uint256(keccak256(abi.encodePacked(_initialHash, _publicInputs)));
        }
        result = result >> PUBLIC_INPUT_SHIFT;
    }
}
