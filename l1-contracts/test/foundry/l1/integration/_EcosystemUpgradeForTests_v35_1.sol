// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreUpgrade_v35} from "deploy-scripts/upgrade/v35/CoreUpgrade_v35.s.sol";
import {CTMUpgradeForTests_v35} from "./_EcosystemUpgradeForTests_v35.sol";

/// @notice A same-minor PATCH prepare: it replaces the VERIFIER and nothing else. The release is
///         the immutable snapshot of the intended contracts, so the new verifier is published as a
///         release copying the departing one except that member — which the pipeline then upgrades
///         to across a patch version edge. See the Patches section of
///         {docs/registry-driven-upgrades.md}.
/// @dev Every other release member is byte-identical, so the prepare reuses it: the only thing this
///      hop deploys on the CTM side is the verifier pair.

/// @dev A patch has no ecosystem leg at all, so nothing is deployed here and no `CoreRegistry`
///      exists for the transition to name.
contract CoreUpgradeForTests_v35_1 is CoreUpgrade_v35 {
    function deployNewEcosystemContractsL1() public virtual override {}
}

contract CTMUpgradeForTests_v35_1 is CTMUpgradeForTests_v35 {
    /// @notice The one change of this patch: a fresh verifier, which the release then pins and the
    ///         upgrade engine installs on every chain from the composed proposal.
    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();
        deployVerifiers();
    }
}
