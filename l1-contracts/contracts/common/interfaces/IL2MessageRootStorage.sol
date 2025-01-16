// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;
/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L1 Messenger contract, responsible for sending messages to L1.
 */
interface IL2MessageRootStorage {
    function addMessageRoot(uint256 chainId, uint256 blockNumber, bytes32 msgRoot) external;

    function msgRoots(uint256 chainId, uint256 blockNumber) external view returns (bytes32);
    function blockNumberFromMsgRoot(bytes32 msgRoot) external view returns (uint256);
    function chainIdFromMsgRoot(bytes32 msgRoot) external view returns (uint256);
}
