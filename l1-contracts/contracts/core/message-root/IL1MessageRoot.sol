// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    /// @notice The chain id of the legacy Era-based Gateway chain.
    /// @dev Lives only on the L1 MessageRoot; used by L1ChainAssetHandler to gate legacy GW migration intervals.
    // solhint-disable-next-line func-name-mixedcase
    function ERA_GATEWAY_CHAIN_ID() external view returns (uint256);

    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);

    function saveV31UpgradeChainBatchNumber(uint256 _chainId) external;

    /// @notice Returns whether a chain has not finalized its v31 upgrade marker yet.
    /// @param _chainId The chain id to query.
    function isPreV31(uint256 _chainId) external view returns (bool);
}
