// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";

/// @title The interface of the Verifier contract, responsible for the zero knowledge proof verification.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IDualVerifier is IVerifier {
    // Mapping-based getters for verifiers
    function plonkVerifiers(uint32 version) external view returns (IVerifier);
    function fflonkVerifiers(uint32 version) external view returns (IVerifierV2);

    // verificationKeyHash methods
    function verificationKeyHash(uint256 verifierType) external view returns (bytes32);
}
