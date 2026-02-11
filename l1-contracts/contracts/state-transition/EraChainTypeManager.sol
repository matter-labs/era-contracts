// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerBase} from "./ChainTypeManagerBase.sol";
import {ChainCreationParams} from "./IChainTypeManager.sol";
import {GenesisIndexStorageZero, GenesisBatchCommitmentZero, GenesisBatchHashZero, GenesisUpgradeZero} from "../common/L1ContractErrors.sol";

/// @title Era Chain Type Manager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract EraChainTypeManager is ChainTypeManagerBase {
    /// @dev Contract is expected to be used as proxy implementation.
    constructor(
        address _bridgehub,
        address _interopCenter,
        address _l1BytecodesSupplier
    ) ChainTypeManagerBase(_bridgehub, _interopCenter, _l1BytecodesSupplier) {}

    /// @notice Updates the parameters with which a new chain is created
    /// @param _chainCreationParams The new chain creation parameters
    function _setChainCreationParams(ChainCreationParams calldata _chainCreationParams) internal override {
        // Validate common parameters
        _validateChainCreationParams(_chainCreationParams);

        // Additional validation for Era chains
        if (_chainCreationParams.genesisIndexRepeatedStorageChanges == uint64(0)) {
            revert GenesisIndexStorageZero();
        }

        // Process the validated parameters
        _processValidatedChainCreationParams(_chainCreationParams);
    }

    /// @notice Validates chain creation parameters common to all chain types
    /// @param _chainCreationParams The chain creation parameters to validate
    function _validateChainCreationParams(
        ChainCreationParams calldata _chainCreationParams
    ) internal pure virtual override {
        if (_chainCreationParams.genesisUpgrade == address(0)) {
            revert GenesisUpgradeZero();
        }
        if (_chainCreationParams.genesisBatchHash == bytes32(0)) {
            revert GenesisBatchHashZero();
        }

        if (_chainCreationParams.genesisBatchCommitment == bytes32(0)) {
            revert GenesisBatchCommitmentZero();
        }
    }
}
