// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice The v36 CTM upgrade — a REGISTRY-DRIVEN edge from v35, run
///         entirely by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition`, committed by the governance call
///         `CTMUpgradeExecutor.applyCTMUpgrade(transition)` the merge derives. No L2
///         leg: the release's L2 bytecode table is unchanged, so the release-pair derivation
///         yields no L2 deployment and the edge composes the all-zero L2 transaction.
/// @dev Its one override replaces the CTM executor; the release side is what a facet/verifier-level
///      upgrade costs in script code.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {
    /// @inheritdoc DefaultCTMUpgrade
    /// @dev v36 changes `CTMUpgradeExecutor`: it applies a `ProxyUpgradeTransition` by delegatecalling the
    ///      engine the transition pins (EVM-1657), which the v35 executor cannot. An ecosystem still
    ///      on the v35 executor gets a successor; one already on this build keeps its own.
    function replacesCTMUpgradeExecutor() internal view virtual override returns (bool) {
        return true;
    }
}
