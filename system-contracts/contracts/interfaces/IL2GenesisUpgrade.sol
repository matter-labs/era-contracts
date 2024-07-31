// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IL2GenesisUpgrade {
    event UpgradeComplete(uint256 _chainId);

    function genesisUpgrade(uint256 _chainId, bytes calldata _forceDeploymentsData) external payable;
}
