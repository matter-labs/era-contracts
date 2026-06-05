// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2GlobalInteropRootImporter} from "./IL2GlobalInteropRootImporter.sol";
import {
    ImporterAlreadyInitialized,
    ImporterNotSupplier,
    ImporterRootMismatch,
    ImporterZeroRoot,
    ImporterZeroSupplier
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2GlobalInteropRootImporter}. Stores global interop-IMT roots imported from L1.
contract L2GlobalInteropRootImporter is IL2GlobalInteropRootImporter {
    /// @dev L1 block number => imported global root.
    mapping(uint256 l1BlockNumber => bytes32 globalRoot) internal _globalRootAt;
    /// @dev L1 block number => imported L1 timestamp.
    mapping(uint256 l1BlockNumber => uint256 timestamp) internal _timestampAt;
    /// @dev L1 block number => imported flag (distinguishes a genuine zero timestamp).
    mapping(uint256 l1BlockNumber => bool imported) internal _imported;
    /// @dev Insertion-ordered list of imported L1 block numbers.
    uint256[] internal _importedBlocks;

    /// @dev Trusted supplier; also serves as the "initialized" flag.
    address internal _supplier;

    /// @notice One-shot initializer.
    /// @param _trustedSupplier The off-chain supplier (EOA in demo) allowed to import roots.
    function initialize(address _trustedSupplier) external {
        if (_supplier != address(0)) revert ImporterAlreadyInitialized();
        if (_trustedSupplier == address(0)) revert ImporterZeroSupplier();
        _supplier = _trustedSupplier;
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function importGlobalRoot(uint256 _l1BlockNumber, uint256 _l1Timestamp, bytes32 _globalRoot) external {
        if (msg.sender != _supplier) revert ImporterNotSupplier(msg.sender);
        if (_globalRoot == bytes32(0)) revert ImporterZeroRoot();

        if (_imported[_l1BlockNumber]) {
            // Idempotent for the exact same root; conflicting re-imports are rejected.
            if (_globalRootAt[_l1BlockNumber] != _globalRoot) {
                revert ImporterRootMismatch(_l1BlockNumber, _globalRootAt[_l1BlockNumber], _globalRoot);
            }
            return;
        }

        _globalRootAt[_l1BlockNumber] = _globalRoot;
        _timestampAt[_l1BlockNumber] = _l1Timestamp;
        _imported[_l1BlockNumber] = true;
        _importedBlocks.push(_l1BlockNumber);

        emit GlobalRootImported(_l1BlockNumber, _l1Timestamp, _globalRoot);
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function globalRootAt(uint256 _l1BlockNumber) external view returns (bytes32) {
        return _globalRootAt[_l1BlockNumber];
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function timestampAt(uint256 _l1BlockNumber) external view returns (uint256) {
        return _timestampAt[_l1BlockNumber];
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function isImported(uint256 _l1BlockNumber) external view returns (bool) {
        return _imported[_l1BlockNumber];
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function importedCount() external view returns (uint256) {
        return _importedBlocks.length;
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function importedBlockAt(uint256 _i) external view returns (uint256) {
        return _importedBlocks[_i];
    }

    /// @inheritdoc IL2GlobalInteropRootImporter
    function supplier() external view returns (address) {
        return _supplier;
    }
}
