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
///      `_proof[2 .. 2+N]`   = the Boojum sub-proof, in the envelope `EraDualVerifier` parses; its leading
///                             word selects the FFLONK (0) or PLONK (1) wrapper.
///      `_proof[2+N .. end]` = the Airbender SNARK, exactly `AIRBENDER_SNARK_PROOF_LENGTH` words.
///      The total length is therefore exact, and an envelope with anything trailing is refused.
///
/// @dev There is no carried-hash slot, unlike the ZKsync OS envelope: Era has no continuation proofs, so a
/// permanently-zero reserved word would be audited surface with no meaning.
///
/// @dev The batch public inputs reach both lanes whole and untruncated, because each lane applies
/// `PUBLIC_INPUT_SHIFT` itself. Shifting here would double-shift them.
contract EraMultiProofVerifier is IVerifier, IEraDualVerifier {
    /// @notice The Boojum router (`EraDualVerifier`), which dispatches the FFLONK and PLONK wrappers.
    /// @dev Immutable: a settable lane would let one key point it at a contract that accepts everything,
    /// which is the one thing requiring two proof systems exists to prevent.
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
        // Exact, not minimum: the Airbender SNARK is fixed-size, so the length is fully determined. Derived
        // by subtracting from `_proof.length` rather than adding to the caller-supplied `_proof[1]`, so an
        // absurd declared length reverts here instead of panicking on overflow.
        if (_proof.length < 2 + AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }
        uint256 boojumLength = _proof[1];
        if (boojumLength != _proof.length - 2 - AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }

        // One verifier instance serves every chain of a protocol version, so the policy is read from the
        // calling chain, which in settlement is that chain's diamond.
        uint8 disabled = IGetters(msg.sender).disabledProofSystems();
        // Re-checked with the setter's own predicate: the guarantee rests on this contract, so it does not
        // trust a value written elsewhere.
        if (disabled >= ALL_PROOF_SYSTEMS_DISABLED) {
            revert InvalidDisabledProofSystemsMask(disabled);
        }

        if (disabled & BOOJUM_PROOF_SYSTEM_DISABLED == 0) {
            // An enabled lane must carry a proof: a zero-length slice reaches a router that treats an empty
            // proof as "skip", silently leaving the lane unverified.
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
