// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AuthoredL2Side, DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {ProtocolVersionFeatures} from "../../utils/ProtocolVersionFeatures.sol";

/// @notice The v36 CTM upgrade — a REGISTRY-DRIVEN edge from v35, run
///         entirely by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition`, plus CTM-domain implementation swaps and the
///         standard L2 leg, which runs `L2DefaultUpgrade`.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {
    /// @notice Deploys the ChainTypeManager, ValidatorTimelock and ServerNotifier implementations
    ///         v36 strips of the bootstrap path; the base pipeline swaps each through the CTM-domain
    ///         `ProxyUpgradeTransition` that `CTMUpgradeExecutor.applyInfrastructureUpgrade` applies.
    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();
        // A CTM already on v36 runs these: a v0.36.x patch departing from it ships no swaps.
        if (
            ProtocolVersionFeatures.has(getOldProtocolVersion(), ProtocolVersionFeatures.CTM_COMMITTED_TRANSITIONS_ONLY)
        ) {
            return;
        }
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract("ChainTypeManager");
        // The timelock proxy has run `MultisigCommitter` since v31 (see `DeployCTM`).
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract("MultisigCommitter");
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier");
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Virtual so bytecode-light test harnesses can substitute an L1-only edge.
    function authorL2Side() internal virtual override returns (AuthoredL2Side memory) {
        return standardL2Side();
    }
}
