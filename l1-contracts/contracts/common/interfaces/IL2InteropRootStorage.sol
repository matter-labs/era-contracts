// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;
/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L2 InteropRootStorage contract,
 * responsible for storing the message roots of other chains on the L2.
 */
interface IL2InteropRootStorage {
    function addInteropRoot(uint256 chainId, uint256 blockNumber, bytes32 interopRoot) external;

    function interopRoots(uint256 chainId, uint256 blockNumber) external view returns (bytes32);
}
