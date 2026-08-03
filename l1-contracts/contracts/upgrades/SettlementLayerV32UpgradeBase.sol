// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {PriorityQueueNotReady} from "../common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "../state-transition/L1StateTransitionErrors.sol";

/// @author Matter Labs
/// @title SettlementLayerV32UpgradeBase
/// @dev Base contract for this release's per-chain upgrades, i.e. for a chain moving from v31.
/// @dev Deliberately does none of {SettlementLayerV31UpgradeBase}'s one-time work: a chain arriving here has
/// already been through v31, so `saveV31UpgradeChainBatchNumber` would revert with
/// `V31UpgradeChainBatchNumberAlreadySet`, resetting the DA validators would drop configuration the chain
/// set after v31, and the `baseTokenHasTotalSupply` backfill has happened.
/// @custom:security-contact security@matterlabs.dev
abstract contract SettlementLayerV32UpgradeBase is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);

        // Refresh the validator used in Priority Mode: this release may deploy a new one, and the chain has
        // to point at whatever the CTM advertises now, same as `DiamondInit` does on chain creation.
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

        if (bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice Construct the final L2 upgrade tx data. Implemented by subclasses.
    /// @param _bridgehub The bridgehub of the ecosystem.
    /// @param _chainId The chain being upgraded.
    /// @param _zksyncOS Whether the chain runs ZKsync OS.
    /// @param _existingTxData The L2 upgrade tx data the CTM upgrade produced.
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view virtual returns (bytes memory);
}
