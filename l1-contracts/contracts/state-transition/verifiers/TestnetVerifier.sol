// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1VerifierFflonk} from "./L1VerifierFflonk.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to skip the zkp verification for the testnet environment.
/// If the proof is not empty, it will verify it using the FFLONK verifier,
/// otherwise, it will skip the verification.
contract TestnetVerifier is IVerifierV2, IVerifier {
    L1VerifierFflonk private immutable fflonkVerifier;

    constructor(address _fflonkVerifier) {
        assert(block.chainid != 1);
        fflonkVerifier = L1VerifierFflonk(_fflonkVerifier);
    }

    /// @dev Verifies a zk-SNARK proof, skipping the verification if the proof is empty.
    /// @inheritdoc IVerifierV2
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) external view override(IVerifier, IVerifierV2) returns (bool) {
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.length == 0) {
            return true;
        }

        // For non-empty proofs, delegate to the FFLONK verifier
        return fflonkVerifier.verify(_publicInputs, _proof);
    }

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys.
    /// @return vkHash The keccak256 hash of the loaded verification keys.
    function verificationKeyHash() external view override(IVerifier, IVerifierV2) returns (bytes32) {
        return fflonkVerifier.verificationKeyHash();
    }
}
