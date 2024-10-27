// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "./IBridgehub.sol";

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IMessageRoot {
    function BRIDGE_HUB() external view returns (IBridgehub);

    function addNewChain(uint256 _chainId) external;

    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;
}
