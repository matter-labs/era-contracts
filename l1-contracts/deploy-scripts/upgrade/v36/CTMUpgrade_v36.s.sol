// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {console} from "forge-std/console.sol";

import {Call} from "contracts/governance/Common.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";

import {AuthoredL2Side, DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {ExternalActionsLib} from "../default-upgrade/ExternalActionsLib.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {ProtocolVersionFeatures} from "../../utils/ProtocolVersionFeatures.sol";

/// @notice The v36 CTM upgrade — a REGISTRY-DRIVEN edge from v35, run
///         by the base pipeline: a fresh release (facets, DiamondInit, upgrade engine)
///         pinned by a write-once `CTMTransition`, plus CTM-domain implementation swaps and the
///         standard L2 leg, which runs `L2DefaultUpgrade`. Its one declared governance action hands
///         the CTM's RollupDAManager to the CTM executor.
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
    function deployUpgradeObjects() public virtual override {
        super.deployUpgradeObjects();
        declareRollupDAManagerHandover();
    }

    /// @notice Declares the governance calls that move the live RollupDAManager to the CTM executor:
    ///         governance nominates the executor, which accepts through `forward`. An outstanding
    ///         nomination of governance is accepted first. Nothing when the executor already holds it,
    ///         or when neither owner nor nominee is the governance signing the bundle (a CTM deployed
    ///         with its own governance): that owner hands it over itself.
    function declareRollupDAManagerHandover() internal {
        address rollupDAManager = ctmAddresses.daAddresses.daContracts.rollupDAManager;
        require(rollupDAManager != address(0), "the CTM's RollupDAManager is unknown");
        address executor = boundCTMUpgradeExecutor();
        address owner = IOwnable(rollupDAManager).owner();
        if (owner == executor) {
            return;
        }
        address governance = ctmGovernance();
        if (owner != governance) {
            if (IOwnable(rollupDAManager).pendingOwner() != governance) {
                console.log("RollupDAManager not handed to the CTM executor: its owner is not the bundle's signer");
                console.log("  RollupDAManager:", rollupDAManager);
                console.log("  owner:", owner);
                return;
            }
            declareExternalAction(
                ExternalActionsLib.PHASE_GOVERNANCE,
                "accept governance's nomination on the RollupDAManager",
                "RollupDAManager pending owner (governance)",
                Call({target: rollupDAManager, value: 0, data: abi.encodeCall(IOwnable.acceptOwnership, ())})
            );
        }
        declareExternalAction(
            ExternalActionsLib.PHASE_GOVERNANCE,
            "nominate the CTM executor on the RollupDAManager",
            "RollupDAManager owner (governance)",
            Call({target: rollupDAManager, value: 0, data: abi.encodeCall(IOwnable.transferOwnership, (executor))})
        );
        Call[] memory accept = new Call[](1);
        accept[0] = Call({target: rollupDAManager, value: 0, data: abi.encodeCall(IOwnable.acceptOwnership, ())});
        declareExternalAction(
            ExternalActionsLib.PHASE_GOVERNANCE,
            "the CTM executor accepts the RollupDAManager",
            "CTM executor owner (governance)",
            Call({target: executor, value: 0, data: abi.encodeCall(IUpgradeExecutorBase.forward, (accept))})
        );
    }

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
        members = new string[](2);
        members[0] = "AdminFacet";
        members[1] = "GettersFacet";
    }
}
