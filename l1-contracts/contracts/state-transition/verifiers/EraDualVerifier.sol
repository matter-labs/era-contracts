// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {
    AIRBENDER_PROOF_SYSTEM,
    ALL_PROOF_SYSTEMS,
    BOOJUM_PROOF_SYSTEM,
    DEFAULT_PROOF_SYSTEMS,
    IEraDualVerifier
} from "../chain-interfaces/IEraDualVerifier.sol";
import {
    EmptyProofLength,
    InvalidProofSystemsMask,
    ProofSystemDisabled,
    Unauthorized,
    UnknownVerifierType
} from "../../common/L1ContractErrors.sol";

/// @notice Minimal view of a ZK chain diamond needed to authorize proof-system policy changes.
/// @dev Declared locally rather than importing `IGetters` to keep the verifier's dependency graph
/// limited to the interfaces it actually calls.
interface IChainAdminGetter {
    function getAdmin() external view returns (address);
}

/// @title ZKsync Era Dual Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps multiple verifier contracts and routes zk-SNARK proof verification
/// to the correct verifier based on the provided proof type. It reuses the same interface as on the original `Verifier`
/// contract, while abusing one of the fields (`_recursiveAggregationInput`) for proof verification type. The contract is
/// needed for the smooth transition between verifier versions (e.g. Boojum PLONK → Boojum FFLONK → Airbender).
contract EraDualVerifier is IVerifier, IEraDualVerifier {
    /// @notice The Boojum FFLONK verifier contract.
    IVerifierV2 public immutable FFLONK_VERIFIER;

    /// @notice The Boojum PLONK verifier contract.
    IVerifier public immutable PLONK_VERIFIER;

    /// @notice The Airbender PLONK verifier contract. Verifies Airbender (RISC-V) FRI proofs
    /// wrapped into a PLONK SNARK, which uses a different verification key than the Boojum
    /// PLONK verifier. A separate FFLONK-wrapped variant may be added in the future.
    IVerifier public immutable AIRBENDER_PLONK_VERIFIER;

    /// @notice Type of verification for Boojum FFLONK verifier.
    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;

    /// @notice Type of verification for Boojum PLONK verifier.
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    /// @notice Type of verification for the Airbender verifier wrapped into PLONK.
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    /// @dev Per-chain proof-system policy. `0` means "never set" and is read as
    /// `DEFAULT_PROOF_SYSTEMS`; the setter rejects `0`, so the two are unambiguous.
    /// Keyed by the chain's diamond proxy, which is the `msg.sender` of `verify`.
    ///
    /// @dev OPERATIONAL NOTE: this policy lives in *this verifier instance*, so anything that changes
    /// which instance (or which diamond) is in play resets a chain to `DEFAULT_PROOF_SYSTEMS`:
    ///  - A CTM upgrade that deploys a new `EraDualVerifier` and repoints `s.verifier`: an
    ///    Airbender-only chain (mask `2`) starts reverting `ProofSystemDisabled` on its next
    ///    `proveBatchesSharedBridge`, and Boojum is silently re-enabled for a chain that had
    ///    deliberately turned it off. Re-apply the policy as part of such an upgrade.
    ///  - Migration to a settlement layer mints a diamond at a new address against that layer's
    ///    verifier, so the policy must be set again there, by that layer's chain admin.
    ///  - Migrating back to L1 reuses the original diamond address, which revives whatever entry was
    ///    left behind here.
    /// All of these fail safe (Airbender off, Boojum on) rather than opening a proof system a chain
    /// did not enable — but they are liveness-affecting and must be part of the upgrade/migration
    /// checklist.
    mapping(address chain => uint8 enabledProofSystems) internal _enabledProofSystems;

    /// @param _fflonkVerifier The address of the Boojum FFLONK verifier contract.
    /// @param _plonkVerifier The address of the Boojum PLONK verifier contract.
    /// @param _airbenderPlonkVerifier The address of the Airbender PLONK verifier contract.
    constructor(IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier, IVerifier _airbenderPlonkVerifier) {
        FFLONK_VERIFIER = _fflonkVerifier;
        PLONK_VERIFIER = _plonkVerifier;
        AIRBENDER_PLONK_VERIFIER = _airbenderPlonkVerifier;
    }

    /// @inheritdoc IEraDualVerifier
    function enabledProofSystems(address _chain) public view returns (uint8) {
        uint8 stored = _enabledProofSystems[_chain];
        return stored == 0 ? DEFAULT_PROOF_SYSTEMS : stored;
    }

    /// @notice Set which proof systems `_chain` accepts. Callable only by that chain's admin.
    /// @param _chain The ZK chain diamond to configure.
    /// @param _newEnabledProofSystems The new mask; must be non-zero (a chain cannot disable every
    ///        proof system) and must not set unknown bits.
    /// @dev Authorized against the chain's own admin, read from the chain itself, so a chain admin
    /// can configure their chain without any ecosystem-level action and without this contract
    /// holding an owner. A caller passing an address that is not a ZK chain can only ever write the
    /// entry for an address whose `getAdmin()` already returns them, which no chain's `verify` reads.
    /// @dev Not part of `IEraDualVerifier`: authorization is based on `msg.sender`, so a wrapper such
    /// as `EraTestnetVerifier` cannot forward this call. Chains behind that wrapper must call its
    /// `DUAL_VERIFIER()` directly.
    function setEnabledProofSystems(address _chain, uint8 _newEnabledProofSystems) external {
        // Validate the mask before the external lookup, so a bad mask is rejected without needing a
        // live chain at `_chain`. `0` would leave the chain unable to prove anything, and bits
        // outside `ALL_PROOF_SYSTEMS` would look like a configured policy while enabling nothing.
        if (_newEnabledProofSystems == 0 || _newEnabledProofSystems > ALL_PROOF_SYSTEMS) {
            revert InvalidProofSystemsMask(_newEnabledProofSystems);
        }

        address chainAdmin = IChainAdminGetter(_chain).getAdmin();
        if (msg.sender != chainAdmin) {
            revert Unauthorized(msg.sender);
        }

        uint8 oldEnabledProofSystems = enabledProofSystems(_chain);
        _enabledProofSystems[_chain] = _newEnabledProofSystems;
        emit EnabledProofSystemsUpdated(_chain, oldEnabledProofSystems, _newEnabledProofSystems);
    }

    /// @notice Routes zk-SNARK proof verification to the appropriate verifier based on the proof type.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The zk-SNARK proof itself.
    /// @dev The first element of the `_proof` determines the verifier type.
    ///     - 0 indicates the Boojum FFLONK verifier should be used.
    ///     - 1 indicates the Boojum PLONK verifier should be used.
    ///     - 2 indicates the Airbender PLONK verifier should be used.
    /// @dev The proof system must also be enabled for the calling chain — see
    /// `setEnabledProofSystems`. `msg.sender` is the chain's diamond proxy, since the Executor facet
    /// calls its verifier directly.
    /// @return Returns `true` if the proof verification succeeds, otherwise throws an error.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        return verifyForChain(msg.sender, _publicInputs, _proof);
    }

    /// @inheritdoc IEraDualVerifier
    function verifyForChain(
        address _chain,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view virtual returns (bool) {
        // Ensure the proof has a valid length (at least one element
        // for the proof system differentiator).
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }

        // The first element of `_proof` determines the verifier type.
        uint256 verifierType = _proof[0];
        if (verifierType == FFLONK_VERIFICATION_TYPE) {
            _requireProofSystemEnabled(_chain, BOOJUM_PROOF_SYSTEM, verifierType);
            return FFLONK_VERIFIER.verify(_publicInputs, _extractProof(_proof));
        } else if (verifierType == PLONK_VERIFICATION_TYPE) {
            _requireProofSystemEnabled(_chain, BOOJUM_PROOF_SYSTEM, verifierType);
            return PLONK_VERIFIER.verify(_publicInputs, _extractProof(_proof));
        } else if (verifierType == AIRBENDER_PLONK_VERIFICATION_TYPE) {
            _requireProofSystemEnabled(_chain, AIRBENDER_PROOF_SYSTEM, verifierType);
            return AIRBENDER_PLONK_VERIFIER.verify(_publicInputs, _extractProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @notice Revert unless `_chain` currently accepts the proof system identified by
    /// `_proofSystemBit`.
    /// @param _verifierType Included in the error so the rejected proof type is visible on-chain.
    function _requireProofSystemEnabled(address _chain, uint8 _proofSystemBit, uint256 _verifierType) internal view {
        if (enabledProofSystems(_chain) & _proofSystemBit == 0) {
            revert ProofSystemDisabled(_chain, _verifierType);
        }
    }

    /// @inheritdoc IVerifier
    /// @dev Used for backward compatibility with older Verifier implementation. Returns PLONK verification key hash.
    function verificationKeyHash() external view returns (bytes32) {
        return PLONK_VERIFIER.verificationKeyHash();
    }

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys from the selected verifier.
    /// @return The keccak256 hash of the loaded verification keys based on the verifier.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        if (_verifierType == FFLONK_VERIFICATION_TYPE) {
            return FFLONK_VERIFIER.verificationKeyHash();
        } else if (_verifierType == PLONK_VERIFICATION_TYPE) {
            return PLONK_VERIFIER.verificationKeyHash();
        } else if (_verifierType == AIRBENDER_PLONK_VERIFICATION_TYPE) {
            return AIRBENDER_PLONK_VERIFIER.verificationKeyHash();
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @notice Extract the proof by removing the first element (proof type differentiator).
    /// @param _proof The proof array.
    /// @return result A new array with the first element removed. The first element was used as a hack
    /// to differentiate between the supported proof types.
    function _extractProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - 1;

        // Allocate memory for the new array (_proof.length - 1) since the first element is omitted.
        result = new uint256[](resultLength);

        // Copy elements starting from index 1 (the second element) of the original array.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x20), mul(resultLength, 0x20))
        }
    }
}
