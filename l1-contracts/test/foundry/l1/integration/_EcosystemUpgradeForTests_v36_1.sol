// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreUpgrade_v36} from "deploy-scripts/upgrade/v36/CoreUpgrade_v36.s.sol";
import {AuthoredL2Side, DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeForTests_v36} from "./_EcosystemUpgradeForTests_v36.sol";

/// @notice A same-minor PATCH prepare: it replaces the VERIFIER and nothing else. The release is
///         the immutable snapshot of the intended contracts, so the new verifier is published as a
///         release copying the departing one except that member — which the pipeline then upgrades
///         to across a patch version edge. See the Patches section of
///         {docs/registry-driven-upgrades.md}.
/// @dev Every other release member is byte-identical, so the prepare reuses it: the only thing this
///      hop deploys on the CTM side is the verifier pair.

/// @dev A patch has no ecosystem leg at all, so nothing is deployed here and no core transition
///      exists for the bundle to apply.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgradeForTests_v36_1 is CoreUpgrade_v36 {
    function deployNewEcosystemContractsL1() public virtual override {}
}

// solhint-disable-next-line contract-name-capwords
contract CTMUpgradeForTests_v36_1 is CTMUpgradeForTests_v36 {
    /// @notice The one change of this patch: a fresh verifier, which the release then pins and the
    ///         upgrade engine installs on every chain from the composed proposal.
    /// @dev Skips v36's L2 delegate composer: a patch carries no L2 leg (see {authorL2Side}).
    function deployNewCTMContracts() public virtual override {
        DefaultCTMUpgrade.deployNewCTMContracts();
        deployVerifiers();
    }

    /// @notice A patch carries no L2 leg, so it authors the L1-only side v36 overrides.
    function authorL2Side() internal virtual override returns (AuthoredL2Side memory side) {
        return side;
    }
}
