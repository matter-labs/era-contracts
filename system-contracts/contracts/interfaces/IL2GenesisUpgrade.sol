// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IL2GenesisUpgrade {
    event UpgradeComplete(uint256 _chainId);

    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _forceDeploymentsData
    ) external payable;
}
