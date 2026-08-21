// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IZKsyncOSDualVerifier} from "../chain-interfaces/IZKsyncOSDualVerifier.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

/// @title Multi-Proof Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Requires BOTH an Airbender proof and a ZiSK proof for each state transition.
///         Only accepts the combined proof type (MULTI_PROOF_TYPE = 5).
///         Single-system proofs (type 2) and mock proofs (type 3) are rejected.
///
/// @dev Proof encoding received from the Executor:
///      proof[0] = proof_type | (verifier_version << 8)
///      proof[1] = previous_hash (used by computeZKsyncOSHash)
///
///      For type 5 (MULTI_PROOF):
///      proof[2]              = N  (number of Airbender proof elements)
///      proof[3 .. 3+N]       = Airbender sub-proof, in the envelope that
///                              `airbenderVerifier` parses:
///                                [3]        = 2 | (verifier_version << 8),
///                                             the ZKsync OS PLONK type and a
///                                             version the dual verifier holds
///                                             a sub-verifier for
///                                [4]        = 0. The dual verifier chains the
///                                             single already-chained value it
///                                             receives, seeded from this word,
///                                             so only zero keeps that chaining
///                                             the identity.
///                                [5 .. 3+N] = Airbender PLONK proof words
///      proof[3+N .. 3+N+24]  = ZiSK SNARK proof (24 uint256 = 768 bytes)
///
///      The ZiSK public values are NOT carried in the proof. Every range,
///      single batch or many, is ONE aggregated proof checked by
///      `ziskRangeVerifier`, which RECONSTRUCTS the 320-byte ZiSK public
///      values on-chain from its own pinned VKs and the batch public inputs
///      (the self-contained seed-0 chain). Reconstructing rather than reading
///      them makes the cross-proof binding inherent: a ZiSK proof that
///      attested to a different state transition would reconstruct a different
///      SNARK signal and fail — there is no separately submitted commitment
///      left to forget to check.
contract MultiProofVerifier is Ownable2Step, IVerifier, IZKsyncOSDualVerifier {
    uint256 internal constant MULTI_PROOF_TYPE = 5;

    /// @notice Inner verifier for Airbender proofs. It is the ZKsync OS dual
    ///         verifier, which owns the versioned FFLONK and PLONK sub-verifier
    ///         registry that this contract exposes.
    IVerifier public airbenderVerifier;
    /// @notice Verifier for the aggregated ZiSK proof. It reconstructs the
    ///         ZiSK public values from its own pinned VKs and checks the SNARK
    ///         for every range size, single batch or many. While unset, every
    ///         proof is rejected.
    IVerifier public ziskRangeVerifier;

    error EmptyProof();
    error UnknownProofType(uint256 proofType);
    error ProofTooShort();
    error AirbenderVerificationFailed();
    error ZiskVerificationFailed();
    error ZiskRangeVerifierNotSet();

    constructor(IVerifier _airbenderVerifier, address _initialOwner) {
        airbenderVerifier = _airbenderVerifier;
        _transferOwnership(_initialOwner);
    }

    /// @notice Update the Airbender verifier.
    function setAirbenderVerifier(IVerifier _verifier) external onlyOwner {
        airbenderVerifier = _verifier;
    }

    /// @notice Update the ZiSK range (aggregated-proof) verifier.
    function setZiskRangeVerifier(IVerifier _verifier) external onlyOwner {
        ziskRangeVerifier = _verifier;
    }

    /// @notice Verify a combined Airbender + ZiSK proof.
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view virtual override returns (bool) {
        if (_proof.length == 0) revert EmptyProof();

        uint256 proofType = _proof[0] & 255;

        if (proofType == MULTI_PROOF_TYPE) {
            return _verifyMultiProof(_publicInputs, _proof);
        }

        revert UnknownProofType(proofType);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return airbenderVerifier.verificationKeyHash();
    }

    /// @notice The FFLONK sub-verifier registered for `_version`.
    /// @dev The registry lives in the wrapped dual verifier, so deployment and
    ///      upgrade tooling that introspects this contract reads that one copy.
    function fflonkVerifiers(uint32 _version) external view returns (IVerifierV2) {
        return IZKsyncOSDualVerifier(address(airbenderVerifier)).fflonkVerifiers(_version);
    }

    /// @notice The PLONK sub-verifier registered for `_version`.
    function plonkVerifiers(uint32 _version) external view returns (IVerifier) {
        return IZKsyncOSDualVerifier(address(airbenderVerifier)).plonkVerifiers(_version);
    }

    /// @dev Verify a multi-proof containing both Airbender and ZiSK sub-proofs.
    function _verifyMultiProof(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) internal view returns (bool) {
        // proof[0] = type | version, proof[1] = previous_hash, proof[2] = N
        if (_proof.length < 3) revert ProofTooShort();

        uint256 airbenderLen = _proof[2];
        // 24 = the ZiSK SNARK proof words. The ZiSK public values are no
        // longer carried: the range verifier reconstructs them on-chain.
        if (_proof.length < 3 + airbenderLen + 24) revert ProofTooShort();

        // --- Airbender verification ---
        // Airbender's public input is the previous_hash-seeded chain over the
        // batch public inputs (a running continuation across ranges).
        uint256[] memory args = new uint256[](1);
        args[0] = _computeZKsyncOSHash(_proof[1], _publicInputs);
        uint256[] memory airbenderProof = new uint256[](airbenderLen);
        for (uint256 i = 0; i < airbenderLen; i++) {
            airbenderProof[i] = _proof[3 + i];
        }
        if (!airbenderVerifier.verify(args, airbenderProof)) {
            revert AirbenderVerificationFailed();
        }

        // --- ZiSK verification ---
        // Every range, single batch or many, is ONE aggregated proof. The
        // range verifier reconstructs the ZiSK public values from its own
        // pinned VKs and these batch public inputs (the self-contained seed-0
        // chain), then checks the SNARK. Nothing about the state transition is
        // read from the submitted proof, so the cross-proof binding is
        // inherent: a ZiSK proof attesting to a different transition would
        // reconstruct a different signal and fail here. Only the 24-word SNARK
        // is passed through.
        IVerifier ziskProofVerifier = ziskRangeVerifier;
        if (address(ziskProofVerifier) == address(0)) {
            revert ZiskRangeVerifierNotSet();
        }
        uint256 ziskStart = 3 + airbenderLen;
        uint256[] memory ziskProof = new uint256[](24);
        for (uint256 i = 0; i < 24; i++) {
            ziskProof[i] = _proof[ziskStart + i];
        }
        if (!ziskProofVerifier.verify(_publicInputs, ziskProof)) {
            revert ZiskVerificationFailed();
        }

        return true;
    }

    /// @dev Compute the ZKsync OS hash: chain public inputs with keccak256 truncated to 224 bits.
    function _computeZKsyncOSHash(
        uint256 initialHash,
        uint256[] calldata _publicInputs
    ) internal pure returns (uint256 result) {
        result = initialHash;
        uint256 i = 0;
        if (result == 0) {
            result = _publicInputs[0];
            i = 1;
        }
        for (; i < _publicInputs.length; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _publicInputs[i]))) >> 32;
        }
    }
}
