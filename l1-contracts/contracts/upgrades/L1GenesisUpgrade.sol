// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgradeGenesis} from "./BaseZkSyncUpgradeGenesis.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL1GenesisUpgrade} from "./IL1GenesisUpgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2CanonicalTransactionLib} from "../state-transition/libraries/L2CanonicalTransactionLib.sol";

import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";

import {ZKChainSpecificForceDeploymentsLib} from "./ZKChainSpecificForceDeploymentsLib.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The genesis upgrade of a new chain: the initialization path of the release its CTM
///         pins. It composes the L2 genesis transaction from that release plus the chain context
///         `DiamondInit` has just installed, and sets it through the shared storage part
///         ({BaseZkSyncUpgrade._upgrade}) — no fabricated transition, no nested diamond cut.
contract L1GenesisUpgrade is IL1GenesisUpgrade, BaseZkSyncUpgradeGenesis {
    /// @inheritdoc IL1GenesisUpgrade
    /// @dev Genesis is deliberately NOT routed through the committed-object entry the registry
    ///      engines share: there is no version edge to schedule, and the verifier is already
    ///      installed by `DiamondInit` from the same release, so it is left untouched here.
    function genesisUpgrade() public override returns (bytes32) {
        uint256 protocolVersion = s.protocolVersion;
        // The chain context is the one `DiamondInit` just installed from this same CTM, so the
        // Bridgehub answers `baseTokenAssetId(s.chainId)` with the value sitting in `s`.
        L2CanonicalTransaction memory l2ProtocolUpgradeTx = _genesisUpgradeTx({
            _release: ICTMRelease(IChainTypeManager(s.chainTypeManager).currentRelease()),
            _bridgehub: s.bridgehub,
            _chainId: s.chainId,
            _protocolVersion: protocolVersion
        });

        _upgrade({
            _newProtocolVersion: protocolVersion,
            _upgradeTimestamp: 0,
            _verifier: address(0),
            _l2ProtocolUpgradeTx: l2ProtocolUpgradeTx
        });

        emit GenesisUpgrade(address(this), l2ProtocolUpgradeTx, protocolVersion);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @inheritdoc IL1GenesisUpgrade
    function genesisUpgradeTx(
        address _release,
        address _bridgehub,
        uint256 _chainId,
        uint256 _protocolVersion
    ) external view returns (L2CanonicalTransaction memory) {
        return
            _genesisUpgradeTx({
                _release: ICTMRelease(_release),
                _bridgehub: _bridgehub,
                _chainId: _chainId,
                _protocolVersion: _protocolVersion
            });
    }

    /// @notice THE genesis composition, reached by both {genesisUpgrade} (with the executing
    ///         chain's own context) and {genesisUpgradeTx} (with explicit context).
    /// @param _release The release the chain is created at — the CTM's `currentRelease`.
    /// @param _bridgehub The Bridgehub of the ecosystem the chain belongs to.
    /// @param _chainId The chain the transaction is composed for.
    /// @param _protocolVersion The packed version the chain starts at.
    function _genesisUpgradeTx(
        ICTMRelease _release,
        address _bridgehub,
        uint256 _chainId,
        uint256 _protocolVersion
    ) internal view returns (L2CanonicalTransaction memory) {
        bytes memory l2GenesisUpgradeCalldata = abi.encodeCall(
            IL2GenesisUpgrade.genesisUpgrade,
            (
                _chainId,
                address(IBridgehubBase(_bridgehub).l1CtmDeployer()),
                _release.fixedForceDeploymentsData(),
                ZKChainSpecificForceDeploymentsLib.build(_bridgehub, _chainId)
            )
        );
        // Genesis installs its L2 contract set through a plain `upgrade` delegate call rather than
        // through an upgrade path's deployment plan: a new chain has nothing force-deployed yet,
        // and routing it through a plan would add deployments the genesis engine does not perform.
        //
        // The envelope's nonce is `protocolUpgradeNonce` — `major << 32 | minor` — which is the
        // bare minor version here, because `BaseZkSyncUpgradeGenesis._setNewProtocolVersion`
        // refuses a non-zero major version on both sides of the edge.
        return
            L2CanonicalTransactionLib.upgradeTransaction(
                _protocolVersion,
                abi.encodeCall(IComplexUpgrader.upgrade, (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata))
            );
    }
}
