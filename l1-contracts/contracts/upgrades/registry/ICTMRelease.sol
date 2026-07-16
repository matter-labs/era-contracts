// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice One facet installed on every chain created from a CTM release.
struct GenesisFacet {
    address facet;
    bool isFreezable;
    bytes4[] selectors;
}

/// @notice Immutable description of one CTM release: the version-INDEPENDENT, reusable
///         genesis / post-upgrade state a chain at this release runs — facets, DiamondInit,
///         base-system hashes, force-deployment data and genesis params.
/// @dev A release deliberately carries NO `protocolVersion` and NO `verifier`: those are
///      version-schedule concerns owned by `ICTMTransition`. A verifier-only patch reuses the
///      same release unchanged, so baking version/verifier in here would make it stale at once.
interface ICTMRelease {
    function isZKsyncOS() external view returns (bool);

    function diamondInit() external view returns (address);

    function genesisFacets() external view returns (GenesisFacet[] memory);

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32);

    function fixedForceDeploymentsData() external view returns (bytes memory);

    function genesisParams() external view returns (address, bytes32, bytes32, uint64);

    /// @notice Reverts unless the release is initialized and every pinned L1 codehash matches.
    function validate() external view;

    function verifyAll() external view returns (bool);
}
