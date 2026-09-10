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
/// @notice Requires BOTH a Boojum proof and an Airbender proof for each Era state transition, unless the
/// calling chain has masked one off. Accepts only the combined proof type.
///
/// @dev Envelope layout:
///      `_proof[0]` = proof type in the low 8 bits; bits 8-255 reserved and must be zero.
///      `_proof[1]` = N, the number of words in the Boojum sub-proof.
///      `_proof[2 .. 2+N]`   = the Boojum sub-proof as `EraDualVerifier` parses it; its leading word
///                             selects the FFLONK (0) or PLONK (1) wrapper.
///      `_proof[2+N .. end]` = the Airbender SNARK, exactly `AIRBENDER_SNARK_PROOF_LENGTH` words.
///      The total length is exact, so a trailing word is refused. 71 words with FFLONK, 91 with PLONK.
///
/// @dev No carried-hash slot, unlike the ZKsync OS envelope: Era has no continuation proofs.
/// @dev Public inputs reach both lanes untruncated; each lane applies `PUBLIC_INPUT_SHIFT` itself.
contract EraMultiProofVerifier is IVerifier, IEraDualVerifier, IEraMultiProofVerifier {
    /// @notice The Boojum router (`EraDualVerifier`), which dispatches the FFLONK and PLONK wrappers.
    /// @dev Immutable, so the pair of proof systems a batch is checked against is a property of the
    /// deployed gate rather than of mutable state.
    IVerifier public immutable BOOJUM_VERIFIER;

    /// @inheritdoc IEraMultiProofVerifier
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

        // Reserved bits must be clear, so a dirty header is not read as a bare type.
        if (_proof[0] >> 8 != 0) {
            revert InvalidProofFormat();
        }
        if ((_proof[0] & 255) != ERA_MULTI_PROOF_TYPE) {
            revert UnknownVerifierType();
        }
        // The Airbender SNARK is fixed-size, so the length is exact rather than a minimum. Derived by
        // subtracting from `_proof.length`, so an out-of-range `_proof[1]` reverts instead of overflowing.
        if (_proof.length < 2 + AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }
        uint256 boojumLength = _proof[1];
        if (boojumLength != _proof.length - 2 - AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }

        // One verifier instance serves every chain of a protocol version, so the policy comes from the
        // calling chain. Resolved through the same getter callers use, so settlement and discovery agree.
        uint8 required = requiredProofSystems(IGetters(msg.sender).disabledProofSystems());

        // One word per lane, since the two systems commit to different `auxiliaryOutputHash` values.
        // A single word is accepted only while the Airbender lane is masked off, which is what keeps
        // Boojum-only settlement working for batches carrying no Airbender commitment.
        //
        // A two-word batch stays acceptable under a masked lane, its Airbender segment riding along
        // unverified. Unlike the ZKsync OS lane, which refuses an envelope it will not fully check: here
        // the kill switch has to rescue batches already committed with Airbender data.
        if (
            _publicInputs.length != 2 && !(required & AIRBENDER_PROOF_SYSTEM_DISABLED == 0 && _publicInputs.length == 1)
        ) {
            revert InvalidPublicInputsLength();
        }

        if (required & BOOJUM_PROOF_SYSTEM_DISABLED != 0) {
            // A zero-length slice reaches a router that treats an empty proof as "skip".
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
    /// @dev Requirement is derived from this, not from `supportedProofSystems`: an unwired lane is
    /// missing, not exempt, so deriving it from the wiring would let `verify` skip that lane and settle
    /// a broken deployment single-proof. Kept required, the call to a zero address reverts instead.
    uint8 internal constant GATE_PROOF_SYSTEMS = BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED;

    /// @inheritdoc IEraMultiProofVerifier
    /// @dev Reports what this deployment can check, so an unwired lane drops out of the answer.
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
        // A mask switching off everything would settle a batch behind no proof at all. Refused here as
        // well as in the setter, so a caller is told what settlement would act on.
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
