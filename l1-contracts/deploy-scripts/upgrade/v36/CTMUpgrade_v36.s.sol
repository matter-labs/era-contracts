// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice The v36 CTM upgrade — the first REGISTRY-DRIVEN edge after the v35 bootstrap, run
///         entirely by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition`, committed by the governance call
///         `CTMUpgradeExecutor.applyCTMUpgrade(transition)` the merge derives.
/// @dev FIXME: v36 changes the `L2Bridgehub` built-in, so the release-pair derivation yields an L2
///      deployment, and an edge with L2 deployments needs an authored delegate (`authorL2Side`, as
///      `CTMUpgrade_v35` does); without one the plan build reverts with `L2PlanNeedsDelegate`.
///      The anvil harness doesn't catch it: its ecosystem is built from the current sources, so
///      its L2 table is unchanged.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {}
