// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IManifestHash} from "./IManifestHash.sol";
import {ProxyUpgradeDomain, ProxyUpgradeRow, ProxyUpgradeTransitionManifest} from "../RegistryTypes.sol";

/// @title Proxy upgrade transition.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a write-once object that pins one domain's proxy implementation
///         swaps for one upgrade, as `fromState -> toState` edges (see {ProxyUpgradeRow}). The
///         domain's executor applies it; see {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev `manifestHash` commits to every value in the manifest, the domain included.
interface IProxyUpgradeTransition is IManifestHash {
    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (ProxyUpgradeTransitionManifest memory);

    /// @notice The domain whose executor may apply this object.
    function domain() external view returns (ProxyUpgradeDomain);

    /// @notice Every proxy participating in this upgrade, as complete typed rows (the slots marked
    ///         "not upgraded" are dropped).
    function rows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice Reverts unless every row's `implNew` is deployed code. The executors call it before
    ///         applying the rows.
    /// @dev It does NOT attest that the code is the reviewed code — that is governance's
    ///      approval of this object's row ADDRESSES, established off-chain before approval (see
    ///      {docs/registry-driven-upgrades.md}).
    function validate() external view;
}
