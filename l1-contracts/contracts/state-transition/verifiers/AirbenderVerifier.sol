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
/// @dev The guest emits `program_output = keccak(prevCommitment | currentCommitment)` — the untruncated
/// transition hash the Executor passes through — and the SNARK public input is that value shifted by
/// `PUBLIC_INPUT_SHIFT`. The audited guest binary is bound inside the recursion circuit rather than carried
/// in the public input, so there is nothing here to re-derive from it.
///
/// @dev The prover also supports binding the guest commitment into the public input. Adopting that mode
/// means a new lane contract and a new gate, so no extension point is kept here for it.
contract AirbenderVerifier is IVerifier {
    /// @notice The generated Airbender PLONK verifier.
    /// @dev Immutable, for the reason given on `EraMultiProofVerifier`'s lanes.
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
        // rather than assumed from the caller.
        if (_publicInputs.length != 1) {
            revert InvalidPublicInputsLength();
        }

        uint256[] memory args = new uint256[](1);
        args[0] = _shiftPublicInput(_publicInputs[0]);
        return AIRBENDER_PLONK_VERIFIER.verify(args, _proof);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view returns (bytes32) {
        return AIRBENDER_PLONK_VERIFIER.verificationKeyHash();
    }

    /// @notice Applies `PUBLIC_INPUT_SHIFT` to the batch's transition hash to get the SNARK public input.
    /// @param _transitionHash The untruncated `keccak(prevCommitment | currentCommitment)` for the batch.
    function _shiftPublicInput(uint256 _transitionHash) internal pure returns (uint256) {
        return _transitionHash >> PUBLIC_INPUT_SHIFT;
    }
}
