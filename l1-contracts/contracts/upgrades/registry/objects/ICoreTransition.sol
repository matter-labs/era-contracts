// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title Core (ecosystem-wide) transition.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a storage-backed, write-once object that pins every
///         ecosystem-wide L1 contract row for one protocol upgrade, as a `fromState -> toState`
///         edge (see {ProxyUpgradeRow}).
/// @dev The object is initialized once from an audited manifest and `manifestHash` commits to
///      every value in it. Version-schedule identity is owned by {ICTMTransition}, not here.
interface ICoreTransition {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every manifest
    ///         value: the single value governance reviews against the audited manifest.
    function manifestHash() external view returns (bytes32);

    /// @notice Every ecosystem contract participating in this upgrade, as complete typed rows —
    ///         one call, no per-key rescans. Consumers iterate these directly.
    function ecosystemRows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice Reverts unless every row's `implNew` is deployed code. THE enforcement surface:
    ///         the paths that apply a core transition call it.
    /// @dev It does NOT attest that the code is the reviewed code — that is governance's
    ///      approval of this object's row ADDRESSES, established off-chain before approval (see
    ///      {docs/registry-driven-upgrades.md}).
    function validate() external view;
}
