// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IStateTransitionGetters {
    function getGovernor() external view returns (address);

    function getBridgehub() external view returns (address);

    function getTotalChains() external view returns (uint256);

    function getChainNumberToContract(uint256 _chainNumber) external view returns (address);

    function getStateTransitionChain(uint256 _chainId) external view returns (address);

    function getStoredBatchZero() external view returns (bytes32);

    function getCutHash() external view returns (bytes32);

    function getDiamondInit() external view returns (address);

    function getUpgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);

    function getProtocolVersion() external view returns (uint256);

}
