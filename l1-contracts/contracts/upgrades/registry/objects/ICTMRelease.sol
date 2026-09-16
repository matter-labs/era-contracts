// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet} from "../RegistryTypes.sol";

/// @notice Immutable description of one CTM release: the version-INDEPENDENT, reusable
///         genesis / post-upgrade state a chain at this release runs — facets, DiamondInit,
///         verifier, force-deployment data and genesis params.
/// @dev A release deliberately carries NO `protocolVersion`: the version schedule is owned by
///      `ICTMTransition`, and one release can serve several versions.
/// @dev A release also carries NO VM flag: every release is a ZKsync OS release.
interface ICTMRelease {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every manifest value:
    ///         the single value governance reviews against the audited manifest.
    function manifestHash() external view returns (bytes32);

    function diamondInit() external view returns (address);

    /// @notice The verifier a chain at this release runs. It is part of the installed chain state
    ///         (`s.verifier`), so it lives here rather than in a version-keyed map: both the
    ///         genesis path and the upgrade path read it from the release they resolve to, which
    ///         is what makes them converge.
    function verifier() external view returns (address);

    function genesisFacets() external view returns (GenesisFacet[] memory);

    function fixedForceDeploymentsData() external view returns (bytes memory);

    /// @notice The release's L2 contract set, indexed by `L2EcosystemContract` — see
    ///         `ReleaseManifest.l2BytecodeInfos`.
    function l2BytecodeInfos() external view returns (bytes[] memory);

    /// @notice The shared system-proxy shell descriptor every table member sits behind — see
    ///         `ReleaseManifest.l2SystemProxyBytecodeInfo`.
    function l2SystemProxyBytecodeInfo() external view returns (bytes memory);

    function genesisParams() external view returns (address, bytes32, uint64);

    /// @notice Whether `_chain`'s live diamond routing is EXACTLY this release's — same facets,
    ///         same per-facet selector sets, nothing extra.
    function verifyChainRouting(address _chain) external view returns (bool);

    /// @notice Reverts unless every contract this release names (DiamondInit, genesis upgrade,
    ///         verifier, every genesis facet) is deployed code. THE enforcement surface: the
    ///         paths that install or apply a release call it.
    /// @dev It does NOT attest that the code is the reviewed code — that is governance's
    ///      approval of this object's member ADDRESSES, established off-chain before approval
    ///      (see {docs/registry-driven-upgrades.md}).
    function validate() external view;
}
