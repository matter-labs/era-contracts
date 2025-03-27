// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;
/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L2 MessageRootStorage contract,
 * responsible for storing the message roots of other chains on the L2.
 */
interface IL2MessageRootStorage {
    function addMessageRoot(uint256 chainId, uint256 blockNumber, bytes32 msgRoot) external;

    function msgRoots(uint256 chainId, uint256 blockNumber) external view returns (bytes32);
}
