// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IKnownCodesStorage {
    event MarkedAsKnown(bytes32 indexed bytecodeHash, bool indexed sendBytecodeToL1);

    function markFactoryDeps(bool _shouldSendToL1, bytes32[] calldata _hashes) external;

    function markBytecodeAsPublished(
        bytes32 _bytecodeHash,
        bytes32 _l1PreimageHash,
        uint256 _l1PreimageBytesLen
    ) external;

    function getMarker(bytes32 _hash) external view returns (uint256);
}
