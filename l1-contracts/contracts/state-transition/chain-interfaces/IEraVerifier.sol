// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @title Era verifier flags
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Implemented by every verifier a chain installs, so tooling can ask a verifier what it is
/// rather than infer it from which getters happen to answer.
interface IEraVerifier {
    /// @notice Whether this verifier skips verification for an empty proof.
    /// @dev Answered by production verifiers too, as `false`. A flag only the testnet build exposes
    /// cannot be told apart from a call that failed for some other reason, which is what forces
    /// callers into probing.
    function isTestnetVerifier() external view returns (bool);
}
