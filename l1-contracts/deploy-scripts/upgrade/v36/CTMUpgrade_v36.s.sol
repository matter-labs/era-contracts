// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AuthoredL2Side, DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";

/// @notice The v36 CTM upgrade — the first REGISTRY-DRIVEN edge after the v35 bootstrap, run
///         entirely by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition`, committed by the governance call
///         `CTMUpgradeExecutor.applyCTMUpgrade(transition)` the merge derives. Its L2 leg is the
///         standard one, which runs `L2DefaultUpgrade`.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {
    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Virtual so bytecode-light test harnesses can substitute an L1-only edge.
    function authorL2Side() internal virtual override returns (AuthoredL2Side memory) {
        return standardL2Side();
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Only the v35 -> v36 edge changes these; a same-minor patch reuses them.
    function changedReleaseMembers() internal view virtual override returns (string[] memory members) {
        if (UpgradeHelperLib.isPatchEdge(getOldProtocolVersion(), getNewProtocolVersion())) {
            return members;
        }
        members = new string[](1);
        members[0] = "AdminFacet";
    }
}
