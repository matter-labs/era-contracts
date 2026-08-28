// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";
import {IGetters} from "../chain-interfaces/IGetters.sol";
import {NonZeroCarriedHash} from "../../common/L1ContractErrors.sol";

/// @title Multi-Proof Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Requires BOTH an Airbender proof and a ZiSK proof for each state transition.
///         Only accepts the combined proof type (MULTI_PROOF_TYPE = 5).
///         Single-system proofs (type 2) and mock proofs (type 3) are rejected.
///
/// @dev Proof encoding received from the Executor:
///      proof[0] = proof_type. This format holds no verifier version, so bits
///                 8-255 are reserved and must be zero.
///      proof[1] = carried hash. Reserved and must be zero.
///
///      For type 5 (MULTI_PROOF):
///      proof[2]              = N  (number of Airbender proof elements)
///      proof[3 .. 3+N]       = Airbender sub-proof, in the envelope that
///                              `airbenderVerifier` parses:
///                                [3]        = ZKSYNC_OS_PLONK_VERIFICATION_TYPE
///                                [4]        = 0. This is the carried-hash slot,
///                                             which the ZKsync OS verifier
///                                             requires to be zero.
///                                [5 .. 3+N] = Airbender PLONK proof words
///      proof[3+N .. 3+N+24]  = ZiSK SNARK proof (24 uint256 = 768 bytes)
///
///      The ZiSK public values are NOT carried in the proof. Every range,
///      single batch or many, is ONE aggregated proof checked by
///      `ziskRangeVerifier`, which RECONSTRUCTS the 576-byte ZiSK public
///      values on-chain from its own pinned VKs and the batch public inputs
///      (the self-contained seed-0 chain). Reconstructing rather than reading
///      them makes the cross-proof binding inherent: a ZiSK proof that
///      attested to a different state transition would reconstruct a different
///      SNARK signal and fail — there is no separately submitted commitment
///      left to forget to check.
contract MultiProofVerifier is IVerifier, IZKsyncOSVerifier {
    uint256 internal constant MULTI_PROOF_TYPE = 5;

    /// @notice Inner verifier for Airbender proofs. It is the ZKsync OS
    ///         verifier, which owns the PLONK sub-verifier that this contract
    ///         exposes.
    /// @dev Immutable: a settable sub-verifier would let one key point either
    ///      side at a contract that accepts everything, which is the one thing
    ///      requiring two proof systems exists to prevent. Replacing a
    ///      sub-verifier means deploying this contract again and repointing the
    ///      chain's verifier slot.
    IVerifier public immutable AIRBENDER_VERIFIER;
    /// @notice Verifier for the aggregated ZiSK proof. It reconstructs the
    ///         ZiSK public values from its own pinned VKs and checks the SNARK
    ///         for every range size, single batch or many.
    IVerifier public immutable ZISK_RANGE_VERIFIER;

    error EmptyProof();
    error InvalidProofFormat();
    error UnknownProofType(uint256 proofType);
    error ProofTooShort();
    error AirbenderVerificationFailed();
    error ZiskVerificationFailed();

    constructor(IVerifier _airbenderVerifier, IVerifier _ziskRangeVerifier) {
        AIRBENDER_VERIFIER = _airbenderVerifier;
        ZISK_RANGE_VERIFIER = _ziskRangeVerifier;
    }

    /// @notice Verify a combined Airbender + ZiSK proof.
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view virtual override returns (bool) {
        if (_proof.length == 0) revert EmptyProof();

        // The header word carries the proof type and nothing else. Bits 8-255
        // are reserved, so a payload that sets any of them is rejected rather
        // than read as a bare type.
        if (_proof[0] >> 8 != 0) revert InvalidProofFormat();

        uint256 proofType = _proof[0] & 255;

        if (proofType == MULTI_PROOF_TYPE) {
            return _verifyMultiProof(_publicInputs, _proof);
        }

        revert UnknownProofType(proofType);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return AIRBENDER_VERIFIER.verificationKeyHash();
    }

    /// @notice The PLONK sub-verifier of the wrapped ZKsync OS verifier.
    /// @dev The sub-verifier lives in the wrapped ZKsync OS verifier, so
    ///      deployment and upgrade tooling that introspects this contract
    ///      reads that one copy.
    // solhint-disable-next-line func-name-mixedcase
    function PLONK_VERIFIER() external view returns (IVerifier) {
        return IZKsyncOSVerifier(address(AIRBENDER_VERIFIER)).PLONK_VERIFIER();
    }

    /// @dev Verify a multi-proof containing both Airbender and ZiSK sub-proofs.
    function _verifyMultiProof(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) internal view returns (bool) {
        // proof[0] = type, proof[1] = carried hash, proof[2] = N
        if (_proof.length < 3) revert ProofTooShort();

        // The carried-hash slot holds a continuation input that the settlement
        // layer does not accept, so it stays reserved and must be zero.
        if (_proof[1] != 0) {
            revert NonZeroCarriedHash();
        }

        uint256 airbenderLen = _proof[2];
        // 24 = the ZiSK SNARK proof words. The ZiSK public values are no
        // longer carried: the range verifier reconstructs them on-chain.
        if (_proof.length < 3 + airbenderLen + 24) revert ProofTooShort();

        // --- Airbender verification ---
        // The batch public inputs reach the ZKsync OS verifier whole. That
        // verifier owns the fold the settlement layer defines, so folding here
        // as well would apply the truncation of a one-element fold twice, and
        // the Airbender lane behind this wrapper would see a value the lane
        // without the wrapper never sees.
        uint256[] memory airbenderProof = new uint256[](airbenderLen);
        for (uint256 i = 0; i < airbenderLen; ++i) {
            airbenderProof[i] = _proof[3 + i];
        }
        if (!AIRBENDER_VERIFIER.verify(_publicInputs, airbenderProof)) {
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
        //
        // One verifier serves every chain of a protocol version
        // (`ChainTypeManager.protocolVersionVerifier`), so the requirement is
        // read from the calling chain rather than held here. The caller is that
        // chain's diamond.
        if (!IGetters(msg.sender).ziskVerificationDisabled()) {
            uint256 ziskStart = 3 + airbenderLen;
            uint256[] memory ziskProof = new uint256[](24);
            for (uint256 i = 0; i < 24; ++i) {
                ziskProof[i] = _proof[ziskStart + i];
            }
            if (!ZISK_RANGE_VERIFIER.verify(_publicInputs, ziskProof)) {
                revert ZiskVerificationFailed();
            }
        }

        return true;
    }
}
