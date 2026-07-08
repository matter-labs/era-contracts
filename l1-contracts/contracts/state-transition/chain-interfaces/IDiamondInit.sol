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

/// @notice The chain-specific, CTM-known half of the initialization data; the chain-independent
///         half (`InitializeDataNewChain`) rides in the committed chain-creation cut and is passed
///         through by the CTM as opaque bytes — so the CTM never re-encodes nested dynamic types.
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

/// @notice The chain-independent half of the initialization data, committed in the
///         chain-creation diamond cut's init calldata (abi-encoded).
/// @param l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
/// @param l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
/// @param l2EvmEmulatorBytecodeHash The hash of EVM emulator L2 bytecode
/// @param facets the facets to install in the diamond, installed by DiamondInit itself
struct InitializeDataNewChain {
    bytes32 l2BootloaderBytecodeHash;
    bytes32 l2DefaultAccountBytecodeHash;
    bytes32 l2EvmEmulatorBytecodeHash;
    FacetInstallation[] facets;
}

interface IDiamondInit {
    /// @param _initData The chain-specific data, filled in by the ChainTypeManager.
    /// @param _newChainData The abi-encoded `InitializeDataNewChain` from the committed
    ///        chain-creation cut, passed through opaquely and decoded here.
    function initialize(InitializeData calldata _initData, bytes calldata _newChainData) external returns (bytes32);
}
