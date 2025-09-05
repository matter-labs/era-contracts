// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMessageRoot} from "./IMessageRoot.sol";

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL2MessageRoot is IMessageRoot {
    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;
}
