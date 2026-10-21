// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IDefaultUpgrade} from "./IDefaultUpgrade.sol";
import {ICommittedUpgrade} from "./registry/objects/ICommittedUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "./registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "./registry/libraries/CTMUpgradeComposer.sol";
import {LiveRoutingReader} from "./registry/libraries/LiveRoutingReader.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The default per-chain upgrade engine: reads everything it applies from the committed
///         `CTMTransition` and its target release, and composes the chain's L2 protocol upgrade
///         transaction once, from that plan and the chain's own identity. See
///         {docs/registry-driven-upgrades.md}.
contract DefaultUpgrade is BaseZkSyncUpgrade, IDefaultUpgrade {
    /// @inheritdoc IDefaultUpgrade
    /// @dev No CTM check: `requireReleaseRouting` below binds the transition to its departing
    ///      release's routing, not to a CTM ({docs/registry-driven-upgrades.md#flow-upgrading}).
    ///      No `validate()` either: the committed cut's init calldata names THIS transition
    ///      address, so the object is the committed one by construction, and its `validate()` ran
    ///      when it was committed; code present then is present now.
    function upgradeFromTransition(address _transition) external returns (bytes32) {
        _requireAllBatchesExecuted();
        ICTMTransition transition = ICTMTransition(_transition);
        // The derived cuts remove the departing RELEASE's routing, not the live one: a chain whose
        // routing drifted from it (a CTM-owner `executeUpgrade` recovery cut) would keep the drift
        // under the new release, or fail mid-cut. Restoring the release's routing is the last
        // step of such a recovery.
        LiveRoutingReader.requireReleaseRouting(ICTMRelease(transition.fromRelease()));
        // The facet cuts MUST stay the first step that changes state. The legacy engine replaced
        // the facets and ran the upgrade inside one diamond cut, so the upgrade always executed
        // against the new routing; applying the derived cut first is what keeps that order.
        _applyDerivedFacetCuts(transition.facetCuts());
        _upgradeFromCommittedObject(transition);
        _enableL1SloadForInterop();
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

    /// @notice Turns L1SLOAD on for a chain whose interop is enabled, see {protocol-docs/l1sload.md#upgrade-from-v35}.
    /// @dev Only on L1, the only layer whose message root enables interop.
    function _enableL1SloadForInterop() internal {
        if (s.zksyncOSL1SloadEnabled) {
            return;
        }
        IMessageRootBase messageRoot = IBridgehubBase(s.bridgehub).messageRoot();
        if (block.chainid != messageRoot.L1_CHAIN_ID()) {
            return;
        }
        if (!IL1MessageRoot(address(messageRoot)).isInteropEnabled(s.chainId)) {
            return;
        }
        s.zksyncOSL1SloadEnabled = true;
        emit IAdmin.NewZKsyncOSL1Sload(false, true);
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
        address newVerifier = ICTMRelease(newRelease).verifier();
        // Checked here, not left to `_upgrade`, which reads zero as "leave unchanged" for genesis.
        if (newVerifier == address(0)) {
            revert ZeroAddress();
        }
        _upgrade({
            _newProtocolVersion: newProtocolVersion,
            _upgradeTimestamp: upgradeTimestamp,
            _verifier: newVerifier,
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
