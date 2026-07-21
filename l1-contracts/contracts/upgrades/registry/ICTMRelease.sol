// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice One facet installed on every chain created from a CTM release.
/// @dev `selectors` is the EXPLICIT, complete routing for this facet — never empty. Releases are
///      the canonical routing source (transitions derive their cuts from release pairs), so the
///      routing must be reviewable data in the manifest, not an execution-time code read.
/// @dev `codehash` is the MANDATORY `EXTCODEHASH` pin of `facet` — verified at initialization
///      and by `validate()` / `verifyAll()`. Pins sit beside the address they protect; there is
///      no detached, optional pin list.
struct GenesisFacet {
    address facet;
    bool isFreezable;
    bytes4[] selectors;
    bytes32 codehash;
}

/// @notice Immutable description of one CTM release: the version-INDEPENDENT, reusable
///         genesis / post-upgrade state a chain at this release runs — facets, DiamondInit,
///         base-system hashes, force-deployment data and genesis params.
/// @dev A release deliberately carries NO `protocolVersion` and NO `verifier`: those are
///      version-schedule concerns owned by `ICTMTransition`. A verifier-only patch reuses the
///      same release unchanged, so baking version/verifier in here would make it stale at once.
/// @dev A release also carries NO VM flag: VM identity is single-sourced from the pinned
///      `DiamondInit`'s `IS_ZKSYNC_OS` immutable, which the CTM validates against its own
///      flavour when the release is pinned (`_setCurrentRelease`).
interface ICTMRelease {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every pinned value,
    ///         and the key under which the deploying factory attests this instance.
    function manifestHash() external view returns (bytes32);

    function diamondInit() external view returns (address);

    function genesisFacets() external view returns (GenesisFacet[] memory);

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32);

    function fixedForceDeploymentsData() external view returns (bytes memory);

    function genesisParams() external view returns (address, bytes32, bytes32, uint64);

    /// @notice Reverts unless the release is initialized and every pinned L1 codehash (facets,
    ///         DiamondInit, genesis upgrade) matches the live code.
    function validate() external view;

    function verifyAll() external view returns (bool);
}
