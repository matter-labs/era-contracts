// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "./IVerifier.sol";

/// @title ZiSK Verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice IVerifier plus the two values every generated ZiSK verifier pins,
///         in their 32-byte wire forms: the four u64 limbs big-endian, in
///         order — exactly the bytes the proof's 320-byte public values carry.
/// @dev MultiProofVerifier reads these to recompute the binding digest an
///      aggregated range proof commits to. The digest preimage embeds the
///      SAME wire forms the single-batch verifier pins, so they are exposed
///      here instead of being duplicated (and drifting) in a second contract.
interface IZiskVerifier is IVerifier {
    /// @notice The pinned guest programVK (ROM Merkle root of the guest ELF):
    ///         public-values bytes [0..32].
    function programVK() external view returns (bytes32);

    /// @notice The pinned vadcop-final root commitment (recursive-setup VK):
    ///         public-values bytes [288..320].
    function rootCVadcopFinal() external view returns (bytes32);
}
