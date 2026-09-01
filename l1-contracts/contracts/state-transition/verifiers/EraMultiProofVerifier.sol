// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IEraDualVerifier} from "../chain-interfaces/IEraDualVerifier.sol";
import {IGetters} from "../chain-interfaces/IGetters.sol";
import {
    EmptyProofLength,
    InvalidDisabledProofSystemsMask,
    InvalidProofFormat,
    UnknownVerifierType
} from "../../common/L1ContractErrors.sol";
import {
    AIRBENDER_PROOF_SYSTEM_DISABLED,
    AIRBENDER_SNARK_PROOF_LENGTH,
    ALL_PROOF_SYSTEMS_DISABLED,
    BOOJUM_PROOF_SYSTEM_DISABLED,
    ERA_MULTI_PROOF_TYPE
} from "../../common/Config.sol";

/// @title Era Multi-Proof Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Requires BOTH a Boojum proof and an Airbender proof for each Era state transition, and accepts
/// only the combined proof type. Two independently built proof systems must agree before a batch settles, so
/// a soundness failure in either one alone cannot finalize an invalid batch.
///
/// @dev Proof encoding received from the Executor:
///      `_proof[0]` = proof type. The type occupies the low 8 bits; bits 8-255 are reserved and must be zero.
///      `_proof[1]` = N, the number of words in the Boojum sub-proof.
///      `_proof[2 .. 2+N]`   = the Boojum sub-proof, in the envelope `EraDualVerifier` parses — its own
///                             leading word selects the FFLONK (0) or PLONK (1) wrapper. Both are Boojum, so
///                             that choice is not a proof-system choice.
///      `_proof[2+N .. end]` = the Airbender SNARK, exactly `AIRBENDER_SNARK_PROOF_LENGTH` words.
///      The total length is therefore exact, and an envelope with anything trailing is refused.
///
/// @dev Unlike the ZKsync OS multi-proof envelope there is no carried-hash slot: Era has no continuation
/// proofs, so a permanently-zero reserved word would be surface with no meaning.
///
/// @dev The batch public inputs reach both lanes whole and untruncated. Each sub-verifier owns its own
/// derivation — each lane applies `PUBLIC_INPUT_SHIFT` itself, and the Airbender lane is the seam where a future
/// guest-bound derivation would live — so folding or shifting here would corrupt one of them.
contract EraMultiProofVerifier is IVerifier, IEraDualVerifier {
    /// @notice The Boojum router (`EraDualVerifier`), which dispatches the FFLONK and PLONK wrappers.
    /// @dev Immutable: a settable sub-verifier would let one key point either lane at a contract that
    /// accepts everything, which is the one thing requiring two proof systems exists to prevent. Replacing a
    /// lane means deploying this contract again and repointing the chain's verifier slot.
    IVerifier public immutable BOOJUM_VERIFIER;

    /// @notice The Airbender verifier, which owns that lane's public-input derivation.
    /// @dev Immutable for the same reason as `BOOJUM_VERIFIER`.
    IVerifier public immutable AIRBENDER_VERIFIER;

    error BoojumVerificationFailed();
    error AirbenderVerificationFailed();

    constructor(IVerifier _boojumVerifier, IVerifier _airbenderVerifier) {
        BOOJUM_VERIFIER = _boojumVerifier;
        AIRBENDER_VERIFIER = _airbenderVerifier;
    }

    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }

        // The header word carries the proof type and nothing else, so a payload smuggled into the reserved
        // bits is rejected rather than read as a bare type.
        if (_proof[0] >> 8 != 0) {
            revert InvalidProofFormat();
        }
        if ((_proof[0] & 255) != ERA_MULTI_PROOF_TYPE) {
            revert UnknownVerifierType();
        }
        // Exact, not minimum: the Airbender SNARK is fixed-size, so the total length is fully determined by
        // the declared Boojum length. Compared by subtracting from `_proof.length` rather than adding to the
        // attacker-supplied `_proof[1]`, so an absurd declared length reverts with this error instead of a
        // checked-arithmetic panic.
        if (_proof.length < 2 + AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }
        uint256 boojumLength = _proof[1];
        if (boojumLength != _proof.length - 2 - AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }

        // One verifier instance serves every chain of a protocol version, so which proof systems are
        // required is read from the calling chain rather than held here. In settlement the caller is that
        // chain's diamond, because the Executor facet calls its verifier directly.
        uint8 disabled = IGetters(msg.sender).disabledProofSystems();
        // `Admin.setDisabledProofSystems` already rejects anything but 0, 1 and 2, but that guard lives in
        // another contract. This is the gate the two-prover guarantee actually rests on, so it re-checks
        // rather than trusting a value written elsewhere — with the same predicate as the setter, so an
        // unknown bit is rejected here too instead of being tolerated.
        if (disabled >= ALL_PROOF_SYSTEMS_DISABLED) {
            revert InvalidDisabledProofSystemsMask(disabled);
        }

        if (disabled & BOOJUM_PROOF_SYSTEM_DISABLED == 0) {
            // An enabled lane must actually carry a proof. Without this, a zero-length Boojum slice reaches
            // a sub-verifier that treats an empty proof as "skip" and the lane is silently not verified —
            // the testnet router does exactly that. The Airbender slot is fixed-size so it cannot be empty,
            // but the check is symmetric because the guarantee is.
            if (boojumLength == 0) {
                revert BoojumVerificationFailed();
            }
            if (!BOOJUM_VERIFIER.verify(_publicInputs, _proof[2:2 + boojumLength])) {
                revert BoojumVerificationFailed();
            }
        }

        if (disabled & AIRBENDER_PROOF_SYSTEM_DISABLED == 0) {
            if (!AIRBENDER_VERIFIER.verify(_publicInputs, _proof[2 + boojumLength:])) {
                revert AirbenderVerificationFailed();
            }
        }

        return true;
    }

    /// @inheritdoc IEraDualVerifier
    /// @dev Deployment and upgrade tooling introspects a chain's verifier for its Boojum sub-verifiers
    /// (`AddressIntrospector` reads them off `IZKChain.getVerifier()`). With the gate installed that is this
    /// contract, so it answers for the router it wraps rather than leaving the staticcall to revert.
    // solhint-disable-next-line func-name-mixedcase
    function FFLONK_VERIFIER() external view returns (IVerifierV2) {
        return IEraDualVerifier(address(BOOJUM_VERIFIER)).FFLONK_VERIFIER();
    }

    /// @inheritdoc IEraDualVerifier
    // solhint-disable-next-line func-name-mixedcase
    function PLONK_VERIFIER() external view returns (IVerifier) {
        return IEraDualVerifier(address(BOOJUM_VERIFIER)).PLONK_VERIFIER();
    }

    /// @inheritdoc IVerifier
    /// @dev Kept for backward compatibility with tooling that reads a single hash off the chain's verifier.
    /// It reports the Boojum lane's key, which is the one that has always been reported for Era chains; the
    /// Airbender lane's key is read from `AIRBENDER_VERIFIER` directly.
    function verificationKeyHash() external view returns (bytes32) {
        return BOOJUM_VERIFIER.verificationKeyHash();
    }
}
