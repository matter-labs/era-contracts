// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerBase} from "./ChainTypeManagerBase.sol";
import {ICTMRelease} from "../upgrades/registry/ICTMRelease.sol";
import {
    GenesisIndexStorageZero,
    GenesisBatchCommitmentZero,
    GenesisBatchHashZero,
    GenesisUpgradeZero,
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
        ICTMRelease release = ICTMRelease(_release);
        release.validate();
        if (release.isZKsyncOS()) {
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

        _storeCurrentRelease(_release);
    }
}
