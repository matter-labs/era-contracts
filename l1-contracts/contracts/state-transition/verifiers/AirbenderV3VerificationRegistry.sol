// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title Airbender v3 verification registry (stateless)
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The registry a generated `GkrWhirVerifier` reports every verified statement to. The
/// generator compiles this contract's address into the verifier, so the verifier has to be
/// regenerated for the address this registry is deployed at.
/// @dev The executor verifies proofs through STATICCALL, so `markVerified` must not write state:
/// a recording registry would make every verification revert. Acceptance is decided by
/// `ZKsyncOSAirbenderV3Verifier`, which reads the same `(publicInput, auxInput)` pair from the
/// verifier's return data and checks it against the batch commitment and the pinned chain hash.
contract AirbenderV3VerificationRegistry {
    /// @notice Accepts a verified statement without recording it.
    function markVerified(bytes32, bytes32) external view {}
}
