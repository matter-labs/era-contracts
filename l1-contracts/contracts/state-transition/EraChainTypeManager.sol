// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerBase} from "./ChainTypeManagerBase.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {ICTMRelease} from "../upgrades/registry/objects/ICTMRelease.sol";
import {
    GenesisIndexStorageZero,
    GenesisBatchCommitmentZero,
    GenesisBatchHashZero,
    GenesisUpgradeZero,
    RegistryMissingBaseSystemHash,
    RegistryWrongVM,
    ZeroAddress
} from "../common/L1ContractErrors.sol";

/// @title Era Chain Type Manager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract EraChainTypeManager is ChainTypeManagerBase {
    /// @dev Contract is expected to be used as proxy implementation.
    constructor(
        address _bridgehub,
        address _interopCenter,
        address _l1BytecodesSupplier,
        address _permissionlessValidator
    ) ChainTypeManagerBase(_bridgehub, _interopCenter, _l1BytecodesSupplier, _permissionlessValidator) {}

    /// @return flag whether CTM is for ZKsync OS or Era VM.
    function isZKsyncOS() external pure override returns (bool) {
        return false;
    }

    function _setCurrentRelease(address _release) internal override {
        if (_release == address(0)) {
            revert ZeroAddress();
        }
        _requireGenuineRelease(_release);
        ICTMRelease release = ICTMRelease(_release);
        release.validate();
        // VM identity is single-sourced from the release's pinned DiamondInit immutable —
        // there is no separate manifest flag to drift from it.
        if (IDiamondInit(release.diamondInit()).IS_ZKSYNC_OS()) {
            revert RegistryWrongVM(false, true);
        }
        // No version check here: a release is version-INDEPENDENT. The release <-> protocol-version
        // binding is established atomically by the transition (which calls `setNewVersionUpgrade`
        // and `setCurrentRelease` from the same pinned object), not re-derived from the release.
        (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        ) = release.genesisParams();

        if (genesisUpgrade == address(0)) {
            revert GenesisUpgradeZero();
        }
        if (genesisBatchHash == bytes32(0)) {
            revert GenesisBatchHashZero();
        }
        if (genesisBatchCommitment == bytes32(0)) {
            revert GenesisBatchCommitmentZero();
        }
        // Era chains require a non-zero genesis repeated-storage index.
        if (genesisIndexRepeatedStorageChanges == uint64(0)) {
            revert GenesisIndexStorageZero();
        }

        // Era chains run all three base-system contracts, and `DiamondInit` rejects a zero hash for
        // any of them at genesis. Enforce the same at release acceptance: a zero hash here would be
        // unreachable for new chains and unrepresentable for existing ones (an upgrade reads zero as
        // "leave unchanged"), which is exactly the release/transition divergence this model rules out.
        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = release
            .baseSystemContractHashes();
        if (bootloaderHash == bytes32(0) || defaultAccountHash == bytes32(0) || evmEmulatorHash == bytes32(0)) {
            revert RegistryMissingBaseSystemHash();
        }
        // NOTE: only the zero case is enforced here. An upgrade additionally runs these through
        // `L2ContractHelper.validateBytecodeHash` (see `BaseZkSyncUpgrade`) while genesis writes them
        // unchecked, so a syntactically MALFORMED nonzero hash still diverges the two paths. Adding
        // that check here is the right follow-up; it is left out for now only because it would
        // invalidate the dummy hashes ~38 existing test fixtures rely on.

        _storeCurrentRelease(_release);
    }
}
