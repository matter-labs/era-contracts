// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";
import {IGetters} from "../chain-interfaces/IGetters.sol";
import {InvalidDisabledProofSystemsMask, NonZeroCarriedHash} from "../../common/L1ContractErrors.sol";
import {
    ZISK_PROOF_SYSTEM_DISABLED,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE,
    ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE,
    ZISK_SNARK_PROOF_LENGTH
} from "../../common/Config.sol";

/// @title Multi-Proof Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Verifies the real proof format selected by each chain's ZiSK switch.
/// @dev See {protocol-docs/multi-proof-verification.md}.
contract MultiProofVerifier is IVerifier, IZKsyncOSVerifier {
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

    /// @inheritdoc IVerifier
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view virtual override returns (bool) {
        return verifyForChain(msg.sender, _publicInputs, _proof);
    }

    /// @notice Verifies a proof using an explicitly supplied chain's policy.
    /// @param _chain Chain whose disabled proof systems determine the accepted format.
    /// @param _publicInputs Batch public inputs.
    /// @param _proof Encoded proof.
    /// @dev Used by the testnet wrapper to preserve its caller's context. The chain's
    /// executor calls `verify`, which always uses msg.sender as the chain.
    function verifyForChain(
        address _chain,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view returns (bool) {
        if (_proof.length == 0) {
            revert EmptyProof();
        }
        if (_proof[0] >> 8 != 0) {
            revert InvalidProofFormat();
        }
        uint256 proofType = _proof[0];
        uint256 requiredType = getProofMode(IGetters(_chain).disabledProofSystems());
        if (proofType != requiredType) {
            revert UnknownProofType(proofType);
        }
        if (requiredType == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            if (!AIRBENDER_VERIFIER.verify(_publicInputs, _proof)) {
                revert AirbenderVerificationFailed();
            }
            return true;
        }
        return _verifyMultiProof(_publicInputs, _proof);
    }

    /// @inheritdoc IZKsyncOSVerifier
    function getProofMode(uint8 _disabledProofSystems) public pure returns (uint256) {
        if (_disabledProofSystems & ~ZISK_PROOF_SYSTEM_DISABLED != 0) {
            revert InvalidDisabledProofSystemsMask(_disabledProofSystems);
        }
        return
            _disabledProofSystems & ZISK_PROOF_SYSTEM_DISABLED == 0
                ? ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE
                : ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
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
        if (_proof.length < 3) {
            revert ProofTooShort();
        }

        // The carried-hash slot holds a continuation input that the settlement
        // layer does not accept, so it stays reserved and must be zero.
        if (_proof[1] != 0) {
            revert NonZeroCarriedHash();
        }

        uint256 airbenderLen = _proof[2];
        // 24 = the ZiSK SNARK proof words. The ZiSK public values are no
        // longer carried: the range verifier reconstructs them on-chain.
        if (_proof.length < 3 + airbenderLen + ZISK_SNARK_PROOF_LENGTH) {
            revert ProofTooShort();
        }

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
        uint256 ziskStart = 3 + airbenderLen;
        uint256[] memory ziskProof = new uint256[](ZISK_SNARK_PROOF_LENGTH);
        for (uint256 i = 0; i < ZISK_SNARK_PROOF_LENGTH; ++i) {
            ziskProof[i] = _proof[ziskStart + i];
        }
        if (!ZISK_RANGE_VERIFIER.verify(_publicInputs, ziskProof)) {
            revert ZiskVerificationFailed();
        }

        return true;
    }
}
