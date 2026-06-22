// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IMessageRoot {
    function BRIDGE_HUB() external view returns (address);

    function addNewChain(uint256 _chainId) external;

    function historicalRoot(uint256 _blockNumber) external view returns (bytes32);
}
