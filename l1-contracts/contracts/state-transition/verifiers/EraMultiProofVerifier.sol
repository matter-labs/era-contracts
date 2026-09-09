// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IEraDualVerifier} from "../chain-interfaces/IEraDualVerifier.sol";
import {IEraMultiProofVerifier} from "../chain-interfaces/IEraMultiProofVerifier.sol";
import {IEraVerifier} from "../chain-interfaces/IEraVerifier.sol";
import {IGetters} from "../chain-interfaces/IGetters.sol";
import {
    EmptyProofLength,
    InvalidDisabledProofSystemsMask,
    InvalidProofFormat,
    InvalidPublicInputsLength,
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
/// the validity of a settled batch does not rest on either one alone.
///
/// @dev Proof encoding received from the Executor. With a FFLONK Boojum proof the envelope is 71 words
///      (2 + 25 + 44); with PLONK, 91. Both are a small fraction of the cost of verifying the two proofs.
/// @dev Layout:
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
contract EraMultiProofVerifier is IVerifier, IEraDualVerifier, IEraMultiProofVerifier {
    /// @notice The Boojum router (`EraDualVerifier`), which dispatches the FFLONK and PLONK wrappers.
    /// @dev Immutable: the two lanes are fixed at deployment, so the pair of proof systems a batch is
    /// checked against is a property of the deployed gate rather than of mutable state.
    IVerifier public immutable BOOJUM_VERIFIER;

    /// @inheritdoc IEraMultiProofVerifier
    /// @dev Immutable for the same reason as `BOOJUM_VERIFIER`. Doubles as the marker a chain checks
    /// before declaring itself multi-proof: a single-system router does not answer this call.
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

        // The header word carries the proof type and nothing else, so a value with data in the reserved
        // bits is rejected rather than read as a bare type.
        if (_proof[0] >> 8 != 0) {
            revert InvalidProofFormat();
        }
        if ((_proof[0] & 255) != ERA_MULTI_PROOF_TYPE) {
            revert UnknownVerifierType();
        }
        // Exact, not minimum: the Airbender SNARK is fixed-size, so the length is fully determined. Derived
        // by subtracting from `_proof.length` rather than adding to the caller-supplied `_proof[1]`, so an
        // out-of-range declared length reverts here instead of overflowing.
        if (_proof.length < 2 + AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }
        uint256 boojumLength = _proof[1];
        if (boojumLength != _proof.length - 2 - AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }

        // One verifier instance serves every chain of a protocol version, so the policy is read from the
        // calling chain, which in settlement is that chain's diamond. Resolved through the same function
        // callers use to ask what this gate would require, so settlement and discovery cannot disagree —
        // and that function re-checks the mask, keeping the both-required property here on its own rather
        // than depending on a value written elsewhere.
        uint8 required = requiredProofSystems(IGetters(msg.sender).disabledProofSystems());

        // One word per lane: the two systems commit to different `auxiliaryOutputHash` values, so a
        // batch has a different transition hash under each.
        //
        // A single word is accepted only while the Airbender lane is masked off. That is what lets
        // the kill switch keep Boojum-only settlement working for batches carrying no Airbender
        // commitment. It also means the converse: with the lane enabled, such a batch cannot be
        // proved here at all — so enabling the lane on a chain with committed-but-unproven batches
        // stalls it until they are drained. `Admin.setProofSystemStatus` enforces that.
        //
        // A two-word batch stays acceptable under a masked lane, and its Airbender segment then rides
        // along unverified. Deliberate, and the opposite of the ZKsync OS lane, which refuses an
        // envelope carrying a component it will not check: here the kill switch has to rescue batches
        // already committed with Airbender data, and refusing them is what a stalled chain cannot
        // afford. Unverified bytes cost calldata and decide nothing.
        if (
            _publicInputs.length != 2 && !(required & AIRBENDER_PROOF_SYSTEM_DISABLED == 0 && _publicInputs.length == 1)
        ) {
            revert InvalidPublicInputsLength();
        }

        if (required & BOOJUM_PROOF_SYSTEM_DISABLED != 0) {
            // An enabled lane must carry a proof: a zero-length slice reaches a router that treats an empty
            // proof as "skip", which would leave the lane unverified.
            if (boojumLength == 0) {
                revert BoojumVerificationFailed();
            }
            if (!BOOJUM_VERIFIER.verify(_publicInputs[0:1], _proof[2:2 + boojumLength])) {
                revert BoojumVerificationFailed();
            }
        }

        if (required & AIRBENDER_PROOF_SYSTEM_DISABLED != 0) {
            if (!AIRBENDER_VERIFIER.verify(_publicInputs[1:2], _proof[2 + boojumLength:])) {
                revert AirbenderVerificationFailed();
            }
        }

        return true;
    }

    /// @notice The pair of systems this contract is built to check, before deployment wiring.
    /// @dev The requirement policy is derived from this rather than from `supportedProofSystems`, and the
    /// difference matters. A lane left at the zero address is missing, not exempt: deriving the policy
    /// from what is wired would answer that such a lane is not required and let `verify` skip it, turning
    /// a broken deployment into a silently single-proof chain. Derived from the constant, the lane stays
    /// required and the call to a zero address reverts. `Admin` is what stops the pairing arising.
    uint8 internal constant GATE_PROOF_SYSTEMS = BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED;

    /// @inheritdoc IEraMultiProofVerifier
    /// @dev Reports what this deployment can actually check, so a lane left unwired is absent from the
    /// answer. That makes it the capability check a chain wants before declaring itself multi-proof.
    function supportedProofSystems() public view virtual returns (uint8) {
        uint8 supported;
        if (address(BOOJUM_VERIFIER) != address(0)) {
            supported |= BOOJUM_PROOF_SYSTEM_DISABLED;
        }
        if (address(AIRBENDER_VERIFIER) != address(0)) {
            supported |= AIRBENDER_PROOF_SYSTEM_DISABLED;
        }
        return supported;
    }

    /// @inheritdoc IEraMultiProofVerifier
    function requiredProofSystems(uint8 _disabledProofSystems) public pure virtual returns (uint8) {
        // The mask that switches off everything this gate checks would settle a batch behind no proof
        // at all. Refused here as well as in the setter, so the answer given to a caller is the same one
        // settlement would act on.
        if (_disabledProofSystems >= ALL_PROOF_SYSTEMS_DISABLED) {
            revert InvalidDisabledProofSystemsMask(_disabledProofSystems);
        }
        return GATE_PROOF_SYSTEMS & ~_disabledProofSystems;
    }

    /// @inheritdoc IEraMultiProofVerifier
    function acceptedProofType() external pure virtual returns (uint256) {
        return ERA_MULTI_PROOF_TYPE;
    }

    /// @inheritdoc IEraVerifier
    function isTestnetVerifier() external view virtual returns (bool) {
        return false;
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
