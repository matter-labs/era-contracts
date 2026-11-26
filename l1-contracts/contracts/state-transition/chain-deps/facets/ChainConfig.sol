// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBase} from "./ZKChainBase.sol";
import {IChainConfig} from "../../chain-interfaces/IChainConfig.sol";
import {ISelfDescribingFacet} from "../../chain-interfaces/ISelfDescribingFacet.sol";
import {ChainConfigUpdate} from "../ZKChainStorage.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {RollupDAManager} from "../../data-availability/RollupDAManager.sol";
import {
    ChainConfigUpdateAlreadyDue,
    NoPendingChainConfigUpdate,
    Unauthorized,
    UpgradeTimestampNotReached,
    ZeroUpgradeTimestamp
} from "../../../common/L1ContractErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @title ChainConfig Contract schedules and applies the chain's configuration updates.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ChainConfigFacet is ZKChainBase, IChainConfig, ISelfDescribingFacet {
    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "ChainConfigFacet";

    /// @notice The RollupDAManager that lists the DA validator pairs a permanent rollup may use.
    /// @dev Internal: AdminFacet serves the `ROLLUP_DA_MANAGER()` getter.
    RollupDAManager internal immutable ROLLUP_DA_MANAGER;

    constructor(RollupDAManager _rollupDAManager) {
        ROLLUP_DA_MANAGER = _rollupDAManager;
    }

    /// @notice Checks that the message sender is the chain admin, the chain type manager or its ValidatorTimelock.
    /// @dev Unlike `onlyAdminOrChainTypeManagerOrValidator`, a validator whitelisted on the chain directly is not
    /// accepted: the ValidatorTimelock checks the caller's `UPGRADER_ROLE` before it forwards the call.
    modifier onlyAdminOrChainTypeManagerOrValidatorTimelock() {
        if (
            msg.sender != s.admin &&
            msg.sender != s.chainTypeManager &&
            msg.sender != IChainTypeManager(s.chainTypeManager).validatorTimelockPostV29()
        ) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IChainConfig
    function scheduleChainConfigUpdate(
        ChainConfigUpdate calldata _update,
        uint256 _timestamp
    ) external onlyAdmin onlySettlementLayer {
        if (_timestamp == 0) {
            revert ZeroUpgradeTimestamp();
        }
        uint256 pendingTimestamp = s.pendingChainConfigUpdateTimestamp;
        // A node may already run the due update, so replacing it takes an explicit `cancelChainConfigUpdate`.
        if (pendingTimestamp != 0 && block.timestamp >= pendingTimestamp) {
            revert ChainConfigUpdateAlreadyDue(pendingTimestamp);
        }
        _validateChainConfigUpdate(_update);

        s.pendingChainConfigUpdate = _update;
        s.pendingChainConfigUpdateTimestamp = _timestamp;
        emit ChainConfigUpdateScheduled(_update, _timestamp);
    }

    /// @inheritdoc IChainConfig
    function cancelChainConfigUpdate() external onlyAdmin {
        if (s.pendingChainConfigUpdateTimestamp == 0) {
            revert NoPendingChainConfigUpdate();
        }
        delete s.pendingChainConfigUpdate;
        delete s.pendingChainConfigUpdateTimestamp;
        emit ChainConfigUpdateCancelled();
    }

    /// @inheritdoc IChainConfig
    function applyChainConfigUpdate(
        address // _chainAddress (unused in this specific implementation)
    ) external onlyAdminOrChainTypeManagerOrValidatorTimelock onlySettlementLayer {
        uint256 timestamp = s.pendingChainConfigUpdateTimestamp;
        if (timestamp == 0) {
            revert NoPendingChainConfigUpdate();
        }
        if (block.timestamp < timestamp) {
            revert UpgradeTimestampNotReached(timestamp, block.timestamp);
        }
        ChainConfigUpdate memory update = s.pendingChainConfigUpdate;
        // The chain's state may have changed since the update was scheduled.
        _validateChainConfigUpdate(update);

        bytes32 oldConfigHash = _getZKsyncOSChainConfigHash();
        _setDAValidatorPair(update.l1DAValidator, update.l2DACommitmentScheme);
        _setPubdataContent(update.pubdataContent);
        _setZKsyncOSMaxTxGasLimit(update.maxTxGasLimit);
        _setZKsyncOSL1TxFiltering(update.l1TxFilteringEnabled);
        _setZKsyncOSLargeContractsEnabled(update.largeContractsEnabled);
        if (_getZKsyncOSChainConfigHash() != oldConfigHash) {
            _enforceNoUnverifiedBatchesForChainConfigUpdate();
        }

        delete s.pendingChainConfigUpdate;
        delete s.pendingChainConfigUpdateTimestamp;
        emit ChainConfigUpdateApplied(update);
    }

    /// @notice Runs the checks of the setters for the fields `_update` changes.
    /// @dev A field the update keeps is not checked, so that keeping a value the chain could no longer set
    /// (e.g. a permanent rollup's DA pair the RollupDAManager has since disallowed) does not block the rest.
    /// @param _update The update to check.
    function _validateChainConfigUpdate(ChainConfigUpdate memory _update) internal view {
        if (_update.l1DAValidator != s.l1DAValidator || _update.l2DACommitmentScheme != s.l2DACommitmentScheme) {
            _validateDAValidatorPair(ROLLUP_DA_MANAGER, _update.l1DAValidator, _update.l2DACommitmentScheme);
        }
        if (_update.pubdataContent != s.pubdataContent) {
            _validatePubdataContentChange();
        }
        if (_update.maxTxGasLimit != _getZKsyncOSMaxTxGasLimit()) {
            _validateZKsyncOSMaxTxGasLimit(_update.maxTxGasLimit);
        }
        if (_update.l1TxFilteringEnabled != s.zksyncOSL1TxFilteringEnabled) {
            _validateZKsyncOSL1TxFiltering(_update.l1TxFilteringEnabled);
        }
    }

    /// @inheritdoc ISelfDescribingFacet
    /// @dev GENERATED by `yarn l1 facet-selectors --fix` from this facet's ABI: every externally
    ///      served function except the unregistered helper views `getName()` and `selectors()`
    ///      (see `Utils.getAllSelectors`), in ascending selector order. Guarded against drift by
    ///      FacetSelfDescription.t.sol and `yarn l1 facet-selectors --check`.
    function selectors() public pure returns (bytes4[] memory result) {
        uint32[3] memory list = [
            // applyChainConfigUpdate(address)
            uint32(0x55540fab),
            // scheduleChainConfigUpdate((address,uint8,uint8,uint64,bool,bool),uint256)
            uint32(0x615b40be),
            // cancelChainConfigUpdate()
            uint32(0xc659d785)
        ];
        uint256 count = list.length;
        result = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            result[i] = bytes4(list[i]);
        }
    }
}
