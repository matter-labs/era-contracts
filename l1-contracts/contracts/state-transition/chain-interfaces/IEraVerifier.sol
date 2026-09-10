// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @title Era verifier flags
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Implemented by every verifier a chain installs.
interface IEraVerifier {
    /// @notice Whether this verifier skips verification for an empty proof.
    /// @dev Production verifiers answer `false` rather than omitting the getter, so callers do not
    /// have to tell a missing function from a failed call.
    function isTestnetVerifier() external view returns (bool);
}
