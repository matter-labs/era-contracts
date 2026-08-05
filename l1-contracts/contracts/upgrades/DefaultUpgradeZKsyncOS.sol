// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DefaultUpgrade} from "./DefaultUpgrade.sol";
import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {L2UpgradeTxLib} from "./L2UpgradeTxLib.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {PriorityQueueNotReady} from "../common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "../state-transition/L1StateTransitionErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title DefaultUpgradeZKsyncOS
/// @notice The default per-chain upgrade for ZKsync OS chains: {DefaultUpgrade} plus the per-chain
/// substitution their L2 upgrade transaction needs.
/// @dev The CTM upgrade emits a single ecosystem-wide L2 upgrade transaction whose inner
/// `IL2V32Upgrade.upgrade` calldata carries a placeholder for the chain-specific force-deployments data.
/// Substituting the real data can only happen per chain, which is what this contract adds, on top of the
/// two preconditions every per-chain upgrade has to hold.
contract DefaultUpgradeZKsyncOS is DefaultUpgrade {
    /// @inheritdoc DefaultUpgrade
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public virtual override returns (bytes32) {
        // The base implementation installs the new protocol version's verifier, which is a freshly deployed
        // contract in this release. A batch committed under the old verifier would no longer be provable, so
        // the chain has to be drained of committed-but-unexecuted batches first (see `_setVerifier`).
        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        // A settlement layer relays other chains' priority operations, so a non-empty queue at upgrade time
        // would carry requests across the version boundary.
        if (IBridgehubBase(s.bridgehub).whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        _proposedUpgrade.l2ProtocolUpgradeTx.data = getL2UpgradeTxData(
            s.bridgehub,
            s.chainId,
            s.zksyncOS,
            _proposedUpgrade.l2ProtocolUpgradeTx.data
        );

        return super.upgrade(_proposedUpgrade);
    }

    /// @notice Rewrite the ecosystem-wide L2 upgrade tx data for this chain.
    /// @dev Also called directly by the server, hence `public` and free of diamond-storage reads.
    /// @param _bridgehub The bridgehub of the ecosystem.
    /// @param _chainId The chain being upgraded.
    /// @param _zksyncOS Whether the chain runs ZKsync OS, taken from diamond storage by the caller.
    /// @param _existingTxData The L2 upgrade tx data the CTM upgrade produced.
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view returns (bytes memory) {
        return L2UpgradeTxLib.rewriteZKsyncOSUpgradeTxData(_bridgehub, _chainId, _zksyncOS, _existingTxData);
    }
}
