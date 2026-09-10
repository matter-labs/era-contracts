// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice The v35 CTM upgrade — the first REGISTRY-DRIVEN edge after the v34 bootstrap, run
///         entirely by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition` that names the core prepare's registry, and
///         exactly three governance calls — `CTMUpgradeExecutor.stage0/1/2(transition)`. No L2
///         leg: the release's L2 bytecode table is unchanged, so the release-pair derivation
///         yields no L2 deployment and the edge composes the all-zero L2 transaction.
/// @dev Nothing to override: this is what a facet/verifier-level upgrade costs in script code.
contract CTMUpgrade_v35 is DefaultCTMUpgrade {}
