// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IZkSyncStateTransitionGetters {
    function governor() external view returns (address);

    function bridgehub() external view returns (address);

    function totalChains() external view returns (uint256);

    function stateTransitionChain(uint256 _chainId) external view returns (address);

    function storedBatchZero() external view returns (bytes32);

    function initialCutHash() external view returns (bytes32);

    function genesisUpgrade() external view returns (address);

    function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);

    function protocolVersion() external view returns (uint256);
}
