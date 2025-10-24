// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

address constant L2_INTEROP_ACCOUNT_ADDR = address(0x000000000000000000000000000000000001000E);
address constant L2_STANDARD_TRIGGER_ACCOUNT_ADDR = address(0x000000000000000000000000000000000001000f);

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
