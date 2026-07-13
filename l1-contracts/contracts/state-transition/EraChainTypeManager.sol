// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerBase} from "./ChainTypeManagerBase.sol";
import {ICTMRegistry} from "../upgrades/registry/ICTMRegistry.sol";
import {
    GenesisIndexStorageZero,
    GenesisBatchCommitmentZero,
    GenesisBatchHashZero,
    GenesisUpgradeZero,
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

    /// @notice Points chain creation at a new genesis `CTMRegistry`, validating the Era-specific
    /// genesis params it pins before storing it.
    /// @param _registry The genesis registry to pin.
    function _setGenesisRegistry(address _registry) internal override {
        if (_registry == address(0)) {
            revert ZeroAddress();
        }
        (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        ) = ICTMRegistry(_registry).genesisParams(protocolVersion);

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

        _storeGenesisRegistry(_registry);
    }
}
