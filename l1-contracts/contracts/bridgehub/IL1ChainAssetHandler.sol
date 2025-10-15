// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1ChainAssetHandler {
    function isMigrationInProgress(uint256 _chainId) external view returns (bool);

    function confirmSuccessfulMigrationToGateway(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;
}
