// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IDefaultUpgrade} from "./IDefaultUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "./registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "./registry/libraries/CTMUpgradeComposer.sol";
import {TransitionManifest} from "./registry/RegistryTypes.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The default per-chain upgrade engine: reads everything it applies from the committed
///         `CTMTransition` and its target release, and composes the chain's L2 protocol upgrade
///         transaction once, from that plan and the chain's own identity. See
///         {docs/registry-driven-upgrades.md}.
contract DefaultUpgrade is BaseZkSyncUpgrade, IDefaultUpgrade {
    /// @inheritdoc IDefaultUpgrade
    /// @dev CTM binding is commitment-based: this init only runs through the cut the chain reads
    ///      from its own CTM (`upgradeCutForVersion`), which derives it from the transition that CTM
    ///      committed — a transition cannot be aimed at a foreign CTM's chains. No `validate()`
    ///      here either: that cut's init calldata names THIS transition address, so the object is
    ///      the committed one by construction, and its pins were checked when it was committed.
    ///      Pins cannot have moved since: an `EXTCODEHASH` is fixed for a non-selfdestructible
    ///      contract.
    function upgradeFromTransition(address _transition) external returns (bytes32) {
        _requireAllBatchesExecuted();
        ICTMTransition transition = ICTMTransition(_transition);
        TransitionManifest memory m = transition.getManifest();
        // Straight from the TARGET release, never from the CTM's live `currentRelease()`: a chain
        // several versions behind executes the transition that names its own next release, and the
        // CTM may already have moved past it.
        ICTMRelease newRelease = ICTMRelease(m.newRelease);

        _applyDerivedFacetCuts(transition.facetCuts());
        _upgrade({
            _newProtocolVersion: m.newProtocolVersion,
            _upgradeTimestamp: m.upgradeTimestamp,
            _verifier: newRelease.verifier(),
            _l2ProtocolUpgradeTx: CTMUpgradeComposer.buildL2UpgradeTxFromPlan({
                _plan: transition.l2Plan(),
                _newRelease: newRelease,
                _newProtocolVersion: m.newProtocolVersion,
                _bridgehub: s.bridgehub,
                _chainId: s.chainId
            })
        });
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @inheritdoc IDefaultUpgrade
    function l2UpgradeTx(
        address _transition,
        address _bridgehub,
        uint256 _chainId
    ) external view returns (L2CanonicalTransaction memory) {
        return CTMUpgradeComposer.buildL2UpgradeTx(ICTMTransition(_transition), _bridgehub, _chainId);
    }
}
