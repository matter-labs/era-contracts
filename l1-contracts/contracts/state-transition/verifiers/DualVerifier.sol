// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {EmptyProofLength, UnknownVerifierType} from "../../common/L1ContractErrors.sol";

/// @title Dual Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps multiple verifier contracts and routes zk-SNARK proof verification
/// to the correct verifier based on the provided proof type. It reuses the same interface as on the original `Verifier`
/// contract, while abusing one of the fields (`_recursiveAggregationInput`) for proof verification type. The contract is
/// needed for the smooth transition between verifier versions (e.g. Boojum PLONK → Boojum FFLONK → Airbender).
contract DualVerifier is IVerifier {
    /// @notice The Boojum FFLONK verifier contract.
    IVerifierV2 public immutable FFLONK_VERIFIER;

    /// @notice The Boojum PLONK verifier contract.
    IVerifier public immutable PLONK_VERIFIER;

    /// @notice The Airbender PLONK verifier contract. Verifies Airbender (RISC-V) FRI proofs
    /// wrapped into a PLONK SNARK, which uses a different verification key than the Boojum
    /// PLONK verifier. A separate FFLONK-wrapped variant may be added in the future.
    IVerifier public immutable AIRBENDER_PLONK_VERIFIER;

    /// @notice Type of verification for Boojum FFLONK verifier.
    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;

    /// @notice Type of verification for Boojum PLONK verifier.
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    /// @notice Type of verification for the Airbender verifier wrapped into PLONK.
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    /// @param _fflonkVerifier The address of the Boojum FFLONK verifier contract.
    /// @param _plonkVerifier The address of the Boojum PLONK verifier contract.
    /// @param _airbenderPlonkVerifier The address of the Airbender PLONK verifier contract.
    constructor(IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier, IVerifier _airbenderPlonkVerifier) {
        FFLONK_VERIFIER = _fflonkVerifier;
        PLONK_VERIFIER = _plonkVerifier;
        AIRBENDER_PLONK_VERIFIER = _airbenderPlonkVerifier;
    }

    /// @notice Routes zk-SNARK proof verification to the appropriate verifier based on the proof type.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The zk-SNARK proof itself.
    /// @dev The first element of the `_proof` determines the verifier type.
    ///     - 0 indicates the Boojum FFLONK verifier should be used.
    ///     - 1 indicates the Boojum PLONK verifier should be used.
    ///     - 2 indicates the Airbender PLONK verifier should be used.
    /// @return Returns `true` if the proof verification succeeds, otherwise throws an error.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        // Ensure the proof has a valid length (at least one element
        // for the proof system differentiator).
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }

        // The first element of `_proof` determines the verifier type.
        uint256 verifierType = _proof[0];
        if (verifierType == FFLONK_VERIFICATION_TYPE) {
            return FFLONK_VERIFIER.verify(_publicInputs, _extractProof(_proof));
        } else if (verifierType == PLONK_VERIFICATION_TYPE) {
            return PLONK_VERIFIER.verify(_publicInputs, _extractProof(_proof));
        } else if (verifierType == AIRBENDER_PLONK_VERIFICATION_TYPE) {
            return AIRBENDER_PLONK_VERIFIER.verify(_publicInputs, _extractProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @inheritdoc IVerifier
    /// @dev Used for backward compatibility with older Verifier implementation. Returns PLONK verification key hash.
    function verificationKeyHash() external view returns (bytes32) {
        return PLONK_VERIFIER.verificationKeyHash();
    }

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys from the selected verifier.
    /// @return The keccak256 hash of the loaded verification keys based on the verifier.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        if (_verifierType == FFLONK_VERIFICATION_TYPE) {
            return FFLONK_VERIFIER.verificationKeyHash();
        } else if (_verifierType == PLONK_VERIFICATION_TYPE) {
            return PLONK_VERIFIER.verificationKeyHash();
        } else if (_verifierType == AIRBENDER_PLONK_VERIFICATION_TYPE) {
            return AIRBENDER_PLONK_VERIFIER.verificationKeyHash();
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @notice Extract the proof by removing the first element (proof type differentiator).
    /// @param _proof The proof array.
    /// @return result A new array with the first element removed. The first element was used as a hack
    /// to differentiate between the supported proof types.
    function _extractProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - 1;

        // Allocate memory for the new array (_proof.length - 1) since the first element is omitted.
        result = new uint256[](resultLength);

        // Copy elements starting from index 1 (the second element) of the original array.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x20), mul(resultLength, 0x20))
        }
    }
}
