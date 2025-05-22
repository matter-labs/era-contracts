// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBridgehub} from "./IBridgehub.sol";

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IMessageRoot {
    function BRIDGE_HUB() external view returns (IBridgehub);

    function setAddresses(address _assetTracker) external;

    function addNewChain(uint256 _chainId) external;

    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;

    function historicalRoot(uint256 _blockNumber) external view returns (bytes32);

    function emitMessageRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _messageRoot) external;
}
