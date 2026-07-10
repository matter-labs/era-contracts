// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice One facet to install in a freshly created chain diamond. The genesis diamond cut
///         carries these instead of full `facetCuts`: `DiamondInit` performs the cut itself, so
///         selector lists are not passed around between contracts.
/// @param facet The facet address.
/// @param isFreezable Whether the facet's selectors can be frozen.
/// @param selectors Pinned selector-list override; empty means "read the facet's own
///        `ISelfDescribingFacet.selectors()`" (the steady state — the pinning exists for facets
///        that do not self-describe, e.g. test-only facets).
struct FacetInstallation {
    address facet;
    bool isFreezable;
    bytes4[] selectors;
}

/// @notice The chain-specific initialization data, filled in by the CTM. This is ALL the calldata
///         `DiamondInit` takes: everything chain-independent (facet set, verifier, base system
///         contract hashes) is read from the genesis registry the CTM pins per protocol version.
/// @param chainId the id of the chain
/// @param bridgehub the address of the bridgehub contract
/// @param chainTypeManager contract's address
/// @param protocolVersion initial protocol version
/// @param validatorTimelock address of the validator timelock that delays execution
/// @param admin address who can manage the contract
/// @param baseTokenAssetId asset id of the base token of the chain
/// @param storedBatchZero hash of the initial genesis batch
// solhint-disable-next-line gas-struct-packing
struct InitializeData {
    uint256 chainId;
    address bridgehub;
    address interopCenter;
    address chainTypeManager;
    uint256 protocolVersion;
    address admin;
    address validatorTimelock;
    bytes32 baseTokenAssetId;
    bytes32 storedBatchZero;
}

interface IDiamondInit {
    /// @param _initData The chain-specific data, filled in by the ChainTypeManager. Everything
    ///        else — the facet set, the verifier and the base system contract hashes — is read
    ///        from the genesis registry the CTM pins (`IChainTypeManager.genesisRegistry`), so
    ///        the committed chain-creation cut carries no init payload at all.
    function initialize(InitializeData calldata _initData) external returns (bytes32);
}
