// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the KnownCodesStorage contract, which is responsible
 * for storing the hashes of the bytecodes that have been published to the network.
 */
interface IKnownCodesStorage {
    event MarkedAsKnown(bytes32 indexed bytecodeHash, bool indexed sendBytecodeToL1);

    function markFactoryDeps(bool _shouldSendToL1, bytes32[] calldata _hashes) external;

    function markBytecodeAsPublished(bytes32 _bytecodeHash) external;

    function getMarker(bytes32 _hash) external view returns (uint256);
}
