// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

address constant L2_INTEROP_ACCOUNT_ADDR = address(0x0000000000000000000000000000000000010019);

struct SystemContractsArgs {
    bool broadcast;
    uint256 l1ChainId;
    uint256 gatewayChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    address l2TokenBeacon;
    address aliasedOwner;
    bool contractsDeployedAlready;
    address l1CtmDeployer;
    uint256 maxNumberOfZKChains;
    address wethToken;
}
