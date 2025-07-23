// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IContractRegistry {
    enum Contract {
        AssetTracker,
        Bridgehub,
        ChainAssetHandler,
        ChainRegistrar,
        CTMDeploymentTracker,
        InteropCenter,
        L1AssetRouter,
        L1ERC20Bridge,
        L1NativeTokenVault,
        L1Nullifier,
        BridgedStandardERC20,
        BridgedTokenBeacon,
        RollupDAManager,
        ValidiumL1DAValidator,
        Verifier,
        VerifierFflonk,
        VerifierPlonk,
        DefaultUpgrade,
        L1GenesisUpgrade,
        ValidatorTimelock,
        MessageRoot,
        ContractRegistry,
        ChainTypeManager,
        WrappedBaseTokenStore, /// todo check if needed 
        L1ByteCodeSupplier, /// todo was removed from contracts, still needed in Server?
        Multicall3
    }

    function contractAddress(Contract _ecosystemContract) external view returns (address);
}