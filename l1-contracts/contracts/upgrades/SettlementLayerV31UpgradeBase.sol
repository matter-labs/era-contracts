// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {BaseTokenPreV31TotalSupplyNotSet, PriorityQueueNotReady} from "../common/L1ContractErrors.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {L2DACommitmentScheme} from "../common/Config.sol";
import {NotAllBatchesExecuted} from "../state-transition/L1StateTransitionErrors.sol";

/// @author Matter Labs
/// @title SettlementLayerV31UpgradeBase
/// @dev Base contract for v31 per-chain upgrades. Handles L1 state updates and
/// delegates L2 tx construction to subclasses (Era vs ZKsyncOS).
/// @custom:security-contact security@matterlabs.dev
abstract contract SettlementLayerV31UpgradeBase is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());

        // Persist the freshly discovered NativeTokenVault address into diamond storage so that
        // subsequent facet calls (Mailbox, Executor, Migrator, etc.) see it without re-querying
        // the bridgehub. DiamondInit does the same on chain creation.
        s.nativeTokenVault = nativeTokenVaultAddr;

        s.__DEPRECATED_l2DAValidator = address(0);
        // Reset DA validators, mirroring what the v30 upgrade did. ZKsync OS chains already reset
        // these during their v30 upgrade, so we only need to do it for Era chains here.
        if (!s.zksyncOS) {
            s.l1DAValidator = address(0);
            s.l2DACommitmentScheme = L2DACommitmentScheme.NONE;
        }

        // Set the permissionless validator used in Priority Mode, same as done in DiamondInit.
        s.priorityModeInfo.permissionlessValidator = IChainTypeManager(s.chainTypeManager).PERMISSIONLESS_VALIDATOR();

        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        proposedUpgrade.l2ProtocolUpgradeTx.data = getL2UpgradeTxData(
            address(bridgehub),
            s.chainId,
            s.zksyncOS,
            proposedUpgrade.l2ProtocolUpgradeTx.data
        );

        super.upgrade(proposedUpgrade);
        IMessageRootBase messageRoot = IMessageRootBase(bridgehub.messageRoot());

        if (s.settlementLayer == address(0)) {
            // slither-disable-next-line reentrancy-no-eth
            IL1MessageRoot(address(messageRoot)).saveV31UpgradeChainBatchNumber(s.chainId);
        }

        if (bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        // Era chains automatically have the base-token total supply tracked.
        // ZKsync OS chains haven't been tracking this value on-chain before v31: existing chains
        // must have had it backfilled while running draft-v31 (`setZKsyncOSPreV31TotalSupply`,
        // which sets this flag). This release has no backfill path, so the upgrade is forbidden
        // until the backfill happened.
        if (!s.zksyncOS) {
            s.baseTokenHasTotalSupply = true;
        } else {
            require(s.baseTokenHasTotalSupply, BaseTokenPreV31TotalSupplyNotSet());
            // The flag is set eagerly when the draft-v31 backfill service transaction is
            // *requested*. An empty priority queue (all batches are executed, see above) proves
            // the transaction also *executed* on L2 — this upgrade removes its L2 entry point,
            // so a still-pending backfill would be lost and the supply permanently undercounted.
            // Queue emptiness is the only execution evidence available on L1 for deployed
            // draft-v31 chains (the request hash was never stored). Anyone can delay the upgrade
            // by front-running it with a fresh priority request; that bounded, attacker-funded
            // griefing is accepted — the executor can submit through a private lane.
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice Construct the final L2 upgrade tx data. Implemented by subclasses.
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view virtual returns (bytes memory);
}
