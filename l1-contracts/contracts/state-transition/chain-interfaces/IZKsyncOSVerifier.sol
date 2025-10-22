// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title The interface of the Verifier contract, responsible for the zero knowledge proof verification.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IZKsyncOSVerifier {
    /// @notice Returns the execution version supported by this verifier.
    function executionVersion() external pure returns (uint32);
}
