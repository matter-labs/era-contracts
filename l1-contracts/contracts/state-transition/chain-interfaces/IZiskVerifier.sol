// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "./IVerifier.sol";

/// @title ZiSK Verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice IVerifier plus the three values every generated ZiSK verifier pins,
///         in their 32-byte wire forms: the four u64 limbs big-endian, in
///         order — exactly the bytes the reconstructed 576-byte public values
///         carry.
/// @dev The ZiSK verifier reconstructs the aggregated proof's public values
///      (and the binding digest) from these pins on-chain, so nothing is read
///      from the submitted proof. They are exposed here so they can be read
///      back off-chain (e.g. the server cross-checks them against the guest
///      VKs) rather than being duplicated (and drifting) elsewhere.
/// @dev Two different guest programs take part in one aggregated proof: the
///      inner state-transition guest proves each batch, and the aggregator
///      guest ingests those inner proofs. Each program has its own programVK,
///      so the verifier pins both and uses each one in one place only.
interface IZiskVerifier is IVerifier {
    /// @notice The pinned programVK (ROM Merkle root) of the inner
    ///         state-transition guest ELF. It enters the binding digest as
    ///         `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`.
    ///         The aggregated proof carries that digest across the first eight
    ///         guest-public slots, public-values bytes [32..96].
    function innerProgramVK() external view returns (bytes32);

    /// @notice The pinned programVK (ROM Merkle root) of the aggregator guest
    ///         ELF. It is the program the aggregated proof attests to, so it
    ///         occupies public-values bytes [0..32].
    function aggregatorProgramVK() external view returns (bytes32);

    /// @notice The pinned vadcop-final root commitment (recursive-setup VK) of
    ///         the ZiSK release. One value serves both roles: it enters the
    ///         binding digest, and it occupies public-values bytes [544..576].
    function rootCVadcopFinal() external view returns (bytes32);
}
