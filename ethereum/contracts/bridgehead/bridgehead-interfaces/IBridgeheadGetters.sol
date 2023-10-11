// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IBridgeheadGetters {
    function getGovernor() external view returns (address);

    /// @return The total number of batchs that were committed & verified & executed
    function getChainImplementation() external view returns (address);

    /// @return The total number of batchs that were committed & verified & executed
    function getChainProxyAdmin() external view returns (address);

    function getPriorityTxMaxGasLimit() external view returns (uint256);

    function getTotaProofSystems() external view returns (uint256);

    /// @return The total number of batchs that were committed & verified & executed
    function getIsProofSystem(address _proofSystem) external view returns (bool);

    function getTotalChains() external view returns (uint256);

    function getChainContract(uint256 _chainId) external view returns (address);

    function getChainProofSystem(uint256 _chainId) external view returns (address);
}
