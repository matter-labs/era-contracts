// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {InvalidPublicInputsLength} from "../../common/L1ContractErrors.sol";
import {PUBLIC_INPUT_SHIFT} from "../../common/Config.sol";

/// @title Airbender Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The Airbender lane of the Era dual-prover gate. Derives the public input an Airbender proof was
/// generated against and hands it to the generated Airbender PLONK verifier.
///
/// @dev The Airbender verifier guest emits `program_output = keccak(prevCommitment | currentCommitment)` —
/// the same transition hash the Boojum lane uses, which the Executor now passes through untruncated. The
/// SNARK public input is that value shifted by `PUBLIC_INPUT_SHIFT`.
///
/// @dev WHERE THE AUDITED GUEST BINARY IS BOUND. The commitment to the guest binary is constrained inside
/// the recursion circuit — the guest's final registers are bound to the audited binary there — so it is not
/// carried in the SNARK public input and there is nothing for this contract to re-derive.
///
/// @dev The prover also supports a mode that lifts the commitment into the SNARK public input. Adopting it
/// means a new lane contract deriving `keccak(programOutput | guestBinaryCommitment) >> PUBLIC_INPUT_SHIFT`
/// from its own pinned commitment, a new gate pointing at it, and a `protocolVersionVerifier` repoint —
/// `EraMultiProofVerifier` holds this lane as an `IVerifier` immutable, so nothing in the Executor, the chain
/// storage, the Admin facet or the kill switch changes. No extension point is kept here for it: the switch
/// redeploys this contract either way.
///
/// @dev The derivation currently coincides with the Boojum lane's. That is expected — both proof systems
/// attest to the same state transition — and it is not what separates the lanes: they are separate because
/// they are different circuits behind different verification keys, reached through two fixed immutables that
/// no caller can re-aim.
contract AirbenderVerifier is IVerifier {
    /// @notice The generated Airbender PLONK verifier.
    /// @dev Immutable: a settable sub-verifier would let one key point this lane at a contract that accepts
    /// everything, which is the one thing requiring two proof systems exists to prevent. Replacing it means
    /// deploying this contract again and repointing the chain's verifier slot.
    IVerifier public immutable AIRBENDER_PLONK_VERIFIER;

    /// @param _airbenderPlonkVerifier The generated Airbender PLONK verifier.
    constructor(IVerifier _airbenderPlonkVerifier) {
        AIRBENDER_PLONK_VERIFIER = _airbenderPlonkVerifier;
    }

    /// @inheritdoc IVerifier
    /// @param _publicInputs The untruncated per-batch transition hash emitted by the Executor.
    /// @param _proof The Airbender PLONK proof, with the routing word already stripped by the caller.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external view returns (bool) {
        // Era proves one batch per call, and `verify` is permissionless, so the length is checked here
        // rather than trusted from the caller.
        if (_publicInputs.length != 1) {
            revert InvalidPublicInputsLength();
        }

        uint256[] memory args = new uint256[](1);
        args[0] = _airbenderPublicInput(_publicInputs[0]);
        return AIRBENDER_PLONK_VERIFIER.verify(args, _proof);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view returns (bytes32) {
        return AIRBENDER_PLONK_VERIFIER.verificationKeyHash();
    }

    /// @notice Derives the Airbender SNARK public input from the batch's transition hash.
    /// @param _transitionHash The untruncated `keccak(prevCommitment | currentCommitment)` for the batch.
    function _airbenderPublicInput(uint256 _transitionHash) internal pure returns (uint256) {
        return _transitionHash >> PUBLIC_INPUT_SHIFT;
    }
}
