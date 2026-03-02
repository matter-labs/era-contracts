// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

address constant L2_INTEROP_ACCOUNT_ADDR = address(0x0000000000000000000000000000000000010019);
address constant L2_STANDARD_TRIGGER_ACCOUNT_ADDR = address(0x0000000000000000000000000000000000010018);

struct SystemContractsArgs {
    bool broadcast;
    uint256 l1ChainId;
    uint256 gatewayChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    address legacySharedBridge;
    address l2TokenBeacon;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedOwner;
    bool contractsDeployedAlready;
    address l1CtmDeployer;
    uint256 maxNumberOfZKChains;
    address wethToken;
}
