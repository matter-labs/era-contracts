// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IEraDualVerifier} from "../chain-interfaces/IEraDualVerifier.sol";
import {IEraMultiProofVerifier} from "../chain-interfaces/IEraMultiProofVerifier.sol";
import {IGetters} from "../chain-interfaces/IGetters.sol";
import {
    AirbenderVerificationFailed,
    BoojumVerificationFailed,
    EmptyProofLength,
    InvalidDisabledProofSystemsMask,
    InvalidProofFormat,
    InvalidPublicInputsLength,
    UnknownVerifierType
} from "../../common/L1ContractErrors.sol";
import {
    AIRBENDER_PROOF_SYSTEM_MASK,
    AIRBENDER_SNARK_PROOF_LENGTH,
    BOOJUM_PROOF_SYSTEM_MASK,
    DisabledProofSystems,
    ERA_MULTI_PROOF_TYPE
} from "../../common/Config.sol";

/// @title Era Multi-Proof Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Requires a proof from every proof system it has a verifier for, unless the calling chain has
/// disabled one of them.
/// @dev Proof layout: `[ERA_MULTI_PROOF_TYPE, N, boojumProof(N words), airbenderProof(44 words)]`, where the
/// Boojum sub-proof is what `EraDualVerifier` accepts. Public inputs: `[boojum, airbender]`, one per system.
contract EraMultiProofVerifier is IVerifier, IEraDualVerifier, IEraMultiProofVerifier {
    /// @inheritdoc IEraMultiProofVerifier
    IVerifier public immutable BOOJUM_VERIFIER;

    /// @inheritdoc IEraMultiProofVerifier
    IVerifier public immutable AIRBENDER_VERIFIER;

    /// @dev Proof type under which `verificationKeyHash(uint256)` reports the Airbender key.
    uint256 internal constant AIRBENDER_VERIFICATION_TYPE = 2;

    constructor(IVerifier _boojumVerifier, IVerifier _airbenderVerifier) {
        BOOJUM_VERIFIER = _boojumVerifier;
        AIRBENDER_VERIFIER = _airbenderVerifier;
    }

    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }
        if (_proof[0] != ERA_MULTI_PROOF_TYPE) {
            revert UnknownVerifierType();
        }
        if (_proof.length < 2 + AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }
        uint256 boojumLength = _proof[1];
        if (boojumLength != _proof.length - 2 - AIRBENDER_SNARK_PROOF_LENGTH) {
            revert InvalidProofFormat();
        }
        if (_publicInputs.length != 2) {
            revert InvalidPublicInputsLength();
        }

        // The per-chain policy lives on the calling diamond.
        DisabledProofSystems memory disabled = IGetters(msg.sender).disabledProofSystems();
        uint8 disabledMask = (disabled.boojum ? BOOJUM_PROOF_SYSTEM_MASK : 0) |
            (disabled.airbender ? AIRBENDER_PROOF_SYSTEM_MASK : 0);
        uint8 required = requiredProofSystems(disabledMask);

        if (required & BOOJUM_PROOF_SYSTEM_MASK != 0) {
            if (!BOOJUM_VERIFIER.verify(_publicInputs[0:1], _proof[2:2 + boojumLength])) {
                revert BoojumVerificationFailed();
            }
        }

        if (required & AIRBENDER_PROOF_SYSTEM_MASK != 0) {
            if (!AIRBENDER_VERIFIER.verify(_publicInputs[1:2], _proof[2 + boojumLength:])) {
                revert AirbenderVerificationFailed();
            }
        }

        return true;
    }

    /// @inheritdoc IEraMultiProofVerifier
    function supportedProofSystems() public view returns (uint8 supported) {
        if (address(BOOJUM_VERIFIER) != address(0)) {
            supported |= BOOJUM_PROOF_SYSTEM_MASK;
        }
        if (address(AIRBENDER_VERIFIER) != address(0)) {
            supported |= AIRBENDER_PROOF_SYSTEM_MASK;
        }
    }

    /// @inheritdoc IEraMultiProofVerifier
    function requiredProofSystems(uint8 _disabledProofSystems) public view returns (uint8 required) {
        required = supportedProofSystems() & ~_disabledProofSystems;
        if (required == 0) {
            revert InvalidDisabledProofSystemsMask(_disabledProofSystems);
        }
    }

    /// @inheritdoc IEraMultiProofVerifier
    function acceptedProofType() external pure returns (uint256) {
        return ERA_MULTI_PROOF_TYPE;
    }

    /// @inheritdoc IEraMultiProofVerifier
    // solhint-disable-next-line func-name-mixedcase
    function IS_TESTNET_VERIFIER() external pure virtual returns (bool) {
        return false;
    }

    /// @inheritdoc IEraDualVerifier
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
    /// @dev Reports the Boojum key.
    function verificationKeyHash() external view returns (bytes32) {
        return BOOJUM_VERIFIER.verificationKeyHash();
    }

    /// @notice The verification key hash of one sub-verifier: `0` FFLONK, `1` PLONK, `2` Airbender.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        if (_verifierType == AIRBENDER_VERIFICATION_TYPE) {
            return AIRBENDER_VERIFIER.verificationKeyHash();
        }
        return IEraDualVerifier(address(BOOJUM_VERIFIER)).verificationKeyHash(_verifierType);
    }
}
