// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IEraDualVerifier} from "../chain-interfaces/IEraDualVerifier.sol";
import {EmptyProofLength, InvalidPublicInputsLength, UnknownVerifierType} from "../../common/L1ContractErrors.sol";
import {PUBLIC_INPUT_SHIFT} from "../../common/Config.sol";

/// @title ZKsync Era Dual Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps the two Boojum verifier contracts and routes zk-SNARK proof verification
/// to the correct verifier based on the provided proof type. It reuses the same interface as on the original `Verifier`
/// contract, while abusing one of the fields (`_recursiveAggregationInput`) for proof verification type. The contract is
/// needed for the smooth transition between verifier versions (e.g. Boojum PLONK → Boojum FFLONK → Airbender).
contract EraDualVerifier is IVerifier, IEraDualVerifier {
    /// @notice The Boojum FFLONK verifier contract.
    IVerifierV2 public immutable FFLONK_VERIFIER;

    /// @notice The Boojum PLONK verifier contract.
    IVerifier public immutable PLONK_VERIFIER;

    /// @notice Type of verification for Boojum FFLONK verifier.
    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;

    /// @notice Type of verification for Boojum PLONK verifier.
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    /// @param _fflonkVerifier The address of the Boojum FFLONK verifier contract.
    /// @param _plonkVerifier The address of the Boojum PLONK verifier contract.
    constructor(IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier) {
        FFLONK_VERIFIER = _fflonkVerifier;
        PLONK_VERIFIER = _plonkVerifier;
    }

    /// @notice Routes zk-SNARK proof verification to the appropriate verifier based on the proof type.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The zk-SNARK proof itself.
    /// @dev The first element of the `_proof` determines the verifier type.
    ///     - 0 indicates the Boojum FFLONK verifier should be used.
    ///     - 1 indicates the Boojum PLONK verifier should be used.
    /// @dev Airbender is deliberately not routable here. It is a separate proof system with its own
    /// public-input binding, reached only through `AirbenderVerifier`. An Airbender route inside this router
    /// would make the Boojum lane of `EraMultiProofVerifier` satisfiable by an Airbender proof, so the two
    /// lanes would no longer be two proof systems.
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
            return FFLONK_VERIFIER.verify(_shiftPublicInputs(_publicInputs), _extractProof(_proof));
        } else if (verifierType == PLONK_VERIFICATION_TYPE) {
            return PLONK_VERIFIER.verify(_shiftPublicInputs(_publicInputs), _extractProof(_proof));
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
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @notice Applies `PUBLIC_INPUT_SHIFT` to the untruncated transition hash the Executor emitted.
    /// @dev The Executor emits the per-batch transition hash untruncated so that each proof system can
    /// apply its own derivation, so this verifier owns the shift for the Boojum lane.
    /// @dev Unlike `ZKsyncOSVerifier.computeZKsyncOSHash` there is no range fold: Era proves one batch per
    /// call (`CanOnlyProcessOneBatch`), and folding here would define an aggregation rule that no Era prover
    /// implements. `verify` is permissionless, so the length is checked here rather than assumed from the
    /// Executor.
    function _shiftPublicInputs(uint256[] calldata _publicInputs) internal pure returns (uint256[] memory result) {
        if (_publicInputs.length != 1) {
            revert InvalidPublicInputsLength();
        }

        result = new uint256[](1);
        result[0] = _publicInputs[0] >> PUBLIC_INPUT_SHIFT;
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
