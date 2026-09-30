// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2 as console} from "forge-std/Script.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {DeployCTMUtils} from "../../ctm/DeployCTMUtils.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";

/// @notice CTM-side half of the v33 upgrade flow, invoked once per CTM proxy.
///
/// @dev Extends {DefaultCTMUpgrade} directly rather than `CTMUpgrade_v31`, for the reasons given on
///      {CoreUpgrade_v33}. The default scaffold supplies the `L2DefaultUpgrade` L2 side and the
///      `DefaultUpgradeZKsyncOS` per-chain upgrade; this release swaps the latter for
///      `V32UpgradeZKsyncOS`, which adds the v31 base-token backfill prerequisite.
///
/// @dev v33 is ZKsync OS-only. {noGovernancePrepare} rejects an EraVM CTM up front rather than
///      letting the run get as far as deploying contracts, and the Era force-deployment and
///      L2-upgrade-calldata branches the v31 script carried are omitted rather than left as dead
///      code.
///
/// @dev The per-chain upgrade contract is still named `V32UpgradeZKsyncOS`: this release was developed
///      as v32 and renumbered to v33 when genesis moved to `0.33.0`. The L2 side is the release-agnostic
///      `L2DefaultUpgrade` inherited from {DefaultL2UpgradeStrategy}; it initializes the v32 atomic-interop
///      built-ins the first time a chain receives them.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v33 is Script, DefaultCTMUpgrade {
    /// @notice Priority-op lower-bound registry, deployed alongside the per-chain upgrade contract
    ///         which embeds it as an immutable. Lives here rather than in `DeployCTMUtils` because
    ///         nothing outside this release knows about it.

    /// @inheritdoc DeployCTMUtils
    /// @dev Supplies the registry to `V32UpgradeZKsyncOS`'s constructor; everything else falls
    ///      through to the shared implementation.
    function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
        if (keccak256(bytes(contractName)) == keccak256(bytes("V32UpgradeZKsyncOS"))) {
            require(priorityOpLowerBound != address(0), "PriorityOpLowerBound not deployed");
            return abi.encode(priorityOpLowerBound);
        }
        return super.getCreationCalldata(contractName);
    }

    /// @inheritdoc DefaultCTMUpgrade
    function serializeVersionSpecificStateTransition() internal virtual override {
        require(priorityOpLowerBound != address(0), "PriorityOpLowerBound not deployed");
        vm.serializeAddress("state_transition", "priority_op_lower_bound_addr", priorityOpLowerBound);
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Refuses an EraVM CTM before anything is deployed. There is no Era counterpart to this
    ///      release's per-chain upgrade, so a run that got further would either fail late or, worse,
    ///      produce a bundle for an upgrade that cannot be applied.
    function noGovernancePrepare(CTMUpgradeParams memory _params) public virtual override {
        require(
            IChainTypeManager(_params.ctmProxy).isZKsyncOS(),
            "v33 is a ZKsync OS-only release; EraVM CTMs are not supported"
        );
        super.noGovernancePrepare(_params);
    }

    /// @notice Deploy the per-chain upgrade contract.
    /// @dev Only ZKsync OS chains can be upgraded onto this release. There is no Era counterpart, and
    ///      falling back to the v31 one would generate an upgrade that re-runs v31's one-time work, so this
    ///      refuses to produce anything for Era instead.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        // The registry must exist first: the upgrade contract embeds its address as an immutable.
        priorityOpLowerBound = deploySimpleContract("PriorityOpLowerBound");
        console.log("Deployed PriorityOpLowerBound at", priorityOpLowerBound);

        console.log("Deploying V32UpgradeZKsyncOS");
        return deploySimpleContract("V32UpgradeZKsyncOS");
    }
}
