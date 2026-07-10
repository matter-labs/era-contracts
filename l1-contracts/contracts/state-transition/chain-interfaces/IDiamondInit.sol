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

interface IDiamondInit {
    /// @notice ZK chain diamond contract initialization.
    /// @dev The two arguments are the ONLY per-chain data a chain is created with; everything
    ///      else is read from the ChainTypeManager — which is simply `msg.sender`, since the CTM
    ///      is the one deploying the diamond proxy (and delegatecall preserves the sender) — and
    ///      from the genesis registry / bridgehub it points at.
    /// @param _chainId The chain id of the new chain.
    /// @param _admin The address to be set as the chain's admin.
    function initialize(uint256 _chainId, address _admin) external returns (bytes32);
}
