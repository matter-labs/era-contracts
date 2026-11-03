// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title ZiSK SNARK verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice ABI of the verifier of ZiSK's final SNARK, the pilfflonk wrap of the
///         vadcop-final proof. It serves the ZiSK lane alone: the Airbender
///         lane reaches its own Plonk verifier through `IVerifier`.
/// @dev `PilfflonkVerifier` implements it: ZiSK's generated verifier for the
///      release's pilfflonk verification key, vendored unmodified. It changes
///      only when that key changes. See `verifiers/README.md`.
interface IZiskSnarkVerifier {
    /// @notice Verify a ZiSK pilfflonk proof against its public signal.
    /// @param _proof The proof bytes as 69 big-endian words.
    /// @param _pubSignals The circuit's single public signal.
    function verifyProof(bytes32[69] calldata _proof, uint256[1] calldata _pubSignals) external view returns (bool);
}
