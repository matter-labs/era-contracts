// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet} from "../RegistryTypes.sol";

/// @notice Immutable description of one CTM release: the version-INDEPENDENT, reusable
///         genesis / post-upgrade state a chain at this release runs — facets, DiamondInit,
///         verifier, base-system hashes, force-deployment data and genesis params.
/// @dev A release deliberately carries NO `protocolVersion`: the version schedule is owned by
///      `ICTMTransition`, and one release can serve several versions.
/// @dev A release also carries NO VM flag: VM identity is single-sourced from the pinned
///      `DiamondInit`'s `IS_ZKSYNC_OS` immutable, which the CTM validates against its own
///      flavour when the release is pinned (`_setCurrentRelease`).
interface ICTMRelease {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every pinned value:
    ///         the single value governance reviews against the audited manifest.
    function manifestHash() external view returns (bytes32);

    function diamondInit() external view returns (address);

    /// @notice The verifier a chain at this release runs. It is part of the installed chain state
    ///         (`s.verifier`), so it lives here rather than in a version-keyed map: both the
    ///         genesis path and the upgrade path read it from the release they resolve to, which
    ///         is what makes them converge.
    function verifier() external view returns (address);

    function genesisFacets() external view returns (GenesisFacet[] memory);

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32);

    function fixedForceDeploymentsData() external view returns (bytes memory);

    /// @notice The release's L2 contract set, indexed by `L2EcosystemContract` — see
    ///         `ReleaseManifest.l2BytecodeInfos`.
    function l2BytecodeInfos() external view returns (bytes[] memory);

    function genesisParams() external view returns (address, bytes32, bytes32, uint64);

    /// @notice Reverts unless the release is initialized and every pinned L1 codehash (facets,
    ///         DiamondInit, genesis upgrade) matches the live code.
    function validate() external view;

    function verifyAll() external view returns (bool);
}
