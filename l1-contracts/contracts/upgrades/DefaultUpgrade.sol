// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IDefaultUpgrade} from "./IDefaultUpgrade.sol";
import {ICommittedUpgrade} from "./registry/objects/ICommittedUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "./registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "./registry/libraries/CTMUpgradeComposer.sol";
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
        _applyDerivedFacetCuts(transition.facetCuts());
        _upgradeFromCommittedObject(transition);
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

    /// @notice Applies the storage/L2 part of a registry-driven edge from the object the committed
    ///         cut names: the version edge and its schedule, the verifier of the TARGET release,
    ///         and the L2 protocol upgrade transaction composed from the object's plan and the
    ///         executing chain's own identity.
    /// @param _object The `CTMTransition` or `RegistryBootstrapMigration` this cut points at.
    /// @dev The engine takes the whole edge from ONE object rather than from separately supplied
    ///      values, so a version, a schedule, a verifier and an L2 transaction belonging to
    ///      different upgrades cannot be assembled on the way in.
    /// @dev The release comes off the object, never off the CTM's live `currentRelease()`: a chain
    ///      several versions behind executes the object that names its own next release, and the
    ///      CTM may already have moved past it.
    function _upgradeFromCommittedObject(ICommittedUpgrade _object) internal {
        (uint256 newProtocolVersion, uint256 upgradeTimestamp, address newRelease) = _object.upgradeTarget();
        _upgrade({
            _newProtocolVersion: newProtocolVersion,
            _upgradeTimestamp: upgradeTimestamp,
            _verifier: ICTMRelease(newRelease).verifier(),
            _l2ProtocolUpgradeTx: CTMUpgradeComposer.buildL2UpgradeTxFromPlan({
                _plan: _object.l2Plan(),
                _newRelease: ICTMRelease(newRelease),
                _newProtocolVersion: newProtocolVersion,
                _bridgehub: s.bridgehub,
                _chainId: s.chainId
            })
        });
    }
}
