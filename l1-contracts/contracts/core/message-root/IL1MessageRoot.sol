// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice Interface for L1 MessageRoot v31 upgrade functions.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);

    function saveV31UpgradeChainBatchNumber(uint256 _chainId) external;
}
