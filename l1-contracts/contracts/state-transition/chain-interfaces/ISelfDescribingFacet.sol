// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Self-describing facet interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A facet that declares the function selectors it serves, so that diamond cuts can be
///         composed on-chain (`AdminFacet.executeUpgradeBySwaps`) instead of shipping selector
///         lists as calldata.
/// @dev The list is generated from the audited facet source (`forge inspect <Facet>
///      methodIdentifiers`) and hard-coded into the facet's bytecode; auditing the facet source
///      audits the list.
/// @dev The returned list MUST NOT include `selectors()` itself (or other helper views that are
///      not registered in the diamond, such as `getName()`): every self-describing facet exposes
///      it, so registering it would make two such facets collide.
interface ISelfDescribingFacet {
    /// @notice The function selectors this facet serves in the diamond.
    function selectors() external pure returns (bytes4[] memory);
}
