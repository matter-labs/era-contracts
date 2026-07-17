// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerBase} from "./ChainTypeManagerBase.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {ICTMRelease} from "../upgrades/registry/ICTMRelease.sol";
import {
    GenesisBatchHashZero,
    GenesisBatchCommitmentIncorrect,
    GenesisUpgradeZero,
    RegistryWrongVM,
    ZeroAddress
} from "../common/L1ContractErrors.sol";

/// @title ZKsync OS Chain Type Manager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZKsyncOSChainTypeManager is ChainTypeManagerBase {
    /// @dev Contract is expected to be used as proxy implementation.
    constructor(
        address _bridgehub,
        address _interopCenter,
        address _l1BytecodesSupplier,
        address _permissionlessValidator
    ) ChainTypeManagerBase(_bridgehub, _interopCenter, _l1BytecodesSupplier, _permissionlessValidator) {}

    /// @return flag whether CTM is for ZKsync OS or Era VM.
    function isZKsyncOS() external pure override returns (bool) {
        return true;
    }

    function _setCurrentRelease(address _release) internal override {
        if (_release == address(0)) {
            revert ZeroAddress();
        }
        ICTMRelease release = ICTMRelease(_release);
        release.validate();
        // VM identity is single-sourced from the release's pinned DiamondInit immutable —
        // there is no separate manifest flag to drift from it.
        if (!IDiamondInit(release.diamondInit()).IS_ZKSYNC_OS()) {
            revert RegistryWrongVM(true, false);
        }
        // No version check here: a release is version-INDEPENDENT. The release <-> protocol-version
        // binding is established atomically by the transition (which calls `setNewVersionUpgrade`
        // and `setCurrentRelease` from the same pinned object), not re-derived from the release.
        (address genesisUpgrade, bytes32 genesisBatchHash, bytes32 genesisBatchCommitment, ) = release.genesisParams();

        if (genesisUpgrade == address(0)) {
            revert GenesisUpgradeZero();
        }
        if (genesisBatchHash == bytes32(0)) {
            revert GenesisBatchHashZero();
        }
        // For ZKsync OS, the genesis batch commitment must be equal to 1.
        if (genesisBatchCommitment != bytes32(uint256(1))) {
            revert GenesisBatchCommitmentIncorrect();
        }

        _storeCurrentRelease(_release);
    }
}
