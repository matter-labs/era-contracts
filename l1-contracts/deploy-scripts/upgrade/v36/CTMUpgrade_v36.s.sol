// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice The v36 CTM upgrade — the first REGISTRY-DRIVEN edge after the v35 bootstrap, run
///         entirely by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition` that names the core prepare's registry, and
///         exactly one governance call — `EcosystemUpgradeExecutor.execute(operation)`, derived
///         from the operation the base pipeline deploys over it. No L2
///         leg: the release's L2 bytecode table is unchanged, so the release-pair derivation
///         yields no L2 deployment and the edge composes the all-zero L2 transaction.
/// @dev Nothing to override: this is what a facet/verifier-level upgrade costs in script code.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {}
