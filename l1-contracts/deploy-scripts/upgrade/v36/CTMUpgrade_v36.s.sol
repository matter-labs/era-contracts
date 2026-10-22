// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AuthoredL2Side, DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice The v36 CTM upgrade — the first REGISTRY-DRIVEN edge after the v35 bootstrap, run by
///         the base pipeline: a fresh release (facets, DiamondInit, upgrade engine) pinned by a
///         write-once `CTMTransition`, committed by the governance call
///         `CTMUpgradeExecutor.applyCTMUpgrade(transition)` the merge derives. Its L2 leg installs
///         the built-ins whose code changed, derived on-chain from the release pair, and runs
///         `L2DefaultUpgrade` after them.
/// @dev The Migrator facet, `DiamondInit` and `L1GenesisUpgrade` differ from v35 in their metadata only.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {
    /// @inheritdoc DefaultCTMUpgrade
    function changedReleaseMembers() internal view virtual override returns (string[] memory names) {
        names = new string[](8);
        names[0] = "AdminFacet";
        names[1] = "GettersFacet";
        names[2] = "MailboxFacet";
        names[3] = "ExecutorFacet";
        names[4] = "CommitterFacet";
        names[5] = "MigratorFacet";
        names[6] = "DiamondInit";
        names[7] = "L1GenesisUpgrade";
    }

    /// @inheritdoc DefaultCTMUpgrade
    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();
        deployL2DelegateComposer();
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev The standard side. Virtual so bytecode-light test harnesses can substitute an L1-only edge.
    function authorL2Side() internal virtual override returns (AuthoredL2Side memory) {
        return standardL2Side();
    }
}
