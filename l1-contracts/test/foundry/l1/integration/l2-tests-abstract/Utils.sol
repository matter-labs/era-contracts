// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

struct SystemContractsArgs {
    bool broadcast;
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    address legacySharedBridge;
    address l2TokenBeacon;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedOwner;
    bool contractsDeployedAlready;
    address l1CtmDeployer;
}
