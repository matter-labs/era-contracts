// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "./ContractIdentifiers.sol";

/// @title Genesis facet lookup surface of a CTM registry.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The minimal subset a registry must expose so `DiamondInit` (via `RegistryFacetReader`)
///         can install the complete facet set of a newly created chain at genesis: the new
///         protocol version, the facet list, each facet's address, freezability and selector
///         override.
/// @dev `ICTMRegistry` extends this. The full constants-in-bytecode registry (L1) and the
///      storage-backed `GatewayGenesisRegistry` (Gateway) both implement it, so the diamond-side
///      genesis path is identical regardless of which registry the CTM points at.
interface IGenesisFacetRegistry {
    /// @notice The packed SemVer (see `SemVer.sol`) protocol version chains are created at.
    function newProtocolVersion() external view returns (uint256);

    /// @notice The complete facet set installed in every chain diamond at the given protocol
    ///         version.
    function facetList(uint256 _protocolVersion) external view returns (CTMContract[] memory);

    /// @notice Address of a CTM-scoped facet at a given protocol version.
    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external view returns (address);

    /// @notice The pinned selector-list override of a facet at a given protocol version; an empty
    ///         list means "read the facet's own `ISelfDescribingFacet.selectors()`".
    function facetSelectors(CTMContract _facet, uint256 _protocolVersion) external view returns (bytes4[] memory);

    /// @notice Whether the facet's selectors are freezable in the diamond.
    function facetIsFreezable(CTMContract _facet) external view returns (bool);
}
