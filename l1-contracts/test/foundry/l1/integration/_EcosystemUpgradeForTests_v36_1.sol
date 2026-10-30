// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreUpgrade_v36} from "deploy-scripts/upgrade/v36/CoreUpgrade_v36.s.sol";
import {CTMUpgradeForTests_v36} from "./_EcosystemUpgradeForTests_v36.sol";

/// @notice A same-minor PATCH prepare: it replaces `DiamondInit` and nothing else. The release is the immutable
///         snapshot of the intended contracts, so the new member is published as a release copying the departing one
///         except that member — which the pipeline then upgrades to across a patch version edge.
///         See the Patches section of {docs/registry-driven-upgrades.md}.
/// @dev Every other release member is byte-identical, so the prepare reuses it. The patch leaves the verifier
///      alone (the fixture's chains require their second proof system, which the verifier an upgrade prepare deploys
///      lacks) and the genesis upgrade engine too (an edge without an L2 side must keep it).

/// @dev A patch has no ecosystem leg at all, so nothing is deployed here and no core transition
///      exists for the bundle to apply.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgradeForTests_v36_1 is CoreUpgrade_v36 {
    function deployNewEcosystemContractsL1() public virtual override {}
}

// solhint-disable-next-line contract-name-capwords
contract CTMUpgradeForTests_v36_1 is CTMUpgradeForTests_v36 {
    /// @notice The one change of this patch: a fresh `DiamondInit`, which only chains created after it run.
    function changedReleaseMembers() internal view virtual override returns (string[] memory names) {
        names = new string[](1);
        names[0] = "DiamondInit";
    }

    /// @dev Its code is unchanged, so it is redeployed under this run's salt rather than reused.
    function _canReuseReleaseMember(string memory _name, address _live) internal virtual override returns (bool) {
        if (keccak256(bytes(_name)) == keccak256(bytes("DiamondInit"))) {
            return false;
        }
        return super._canReuseReleaseMember(_name, _live);
    }
}
