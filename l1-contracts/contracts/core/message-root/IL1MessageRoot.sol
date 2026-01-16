// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);

    function saveV31UpgradeChainBatchNumber(uint256 _chainId) external;
}
