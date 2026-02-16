// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1, MAX_ALLOWED_NUMBER_OF_MIGRATIONS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {TxStatus} from "../../common/Messaging.sol";
import {IBridgehubBase, BridgehubBurnCTMAssetData} from "../bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetHandler} from "../../bridge/interfaces/IL1AssetHandler.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IChainAssetHandlerShared} from "./IChainAssetHandlerShared.sol";
import {IL1ChainAssetHandler} from "./IL1ChainAssetHandler.sol";
import {MigrationIntervalInvalid, MigrationIntervalNotSet, MigrationNumberMismatch, SettlementLayerMustNotBeL1, IteratedMigrationsNotSupported, HistoricalSettlementLayerMismatch} from "../bridgehub/L1BridgehubErrors.sol";
import {MigrationInterval} from "./IChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase, IL1AssetHandler, IL1ChainAssetHandler, IChainAssetHandlerShared {
    /// @dev The assetId of the ETH.
    bytes32 public immutable override ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 public immutable override L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    IL1Bridgehub public immutable override BRIDGEHUB;

    /// @dev The mapping showing for each chain if migration is in progress or not, used for freezing deposits.
    mapping(uint256 chainId => bool isMigrationInProgress) public isMigrationInProgress;

    /// @notice Tracks migration batch numbers for chains that migrated to Gateway.
    /// @dev Used to validate that settlement layer claims match the batch number.
    /// @dev Migration number 0 is reserved for legacy GW historical data.
    /// @dev Migration numbers 1+ are for regular L1 <-> SL migrations.
    mapping(uint256 chainId => mapping(uint256 migrationNum => MigrationInterval interval)) internal _migrationInterval;

    /// @dev The message root contract. Set via `setAddresses` after deployment because
    /// L1MessageRoot is deployed after L1ChainAssetHandler (so that L1MessageRoot can store
    /// the chain asset handler address as an immutable).
    IMessageRoot internal messageRoot;

    /// @dev The asset router contract. Set via `setAddresses` after deployment because
    /// L1AssetRouter is deployed after L1ChainAssetHandler.
    IAssetRouterBase internal assetRouter;

    /*//////////////////////////////////////////////////////////////
                        GETTERS
    //////////////////////////////////////////////////////////////*/

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (IL1Bridgehub) {
        return BRIDGEHUB;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return messageRoot;
    }

    // solhint-disable-next-line func-name-mixedcase
    function MESSAGE_ROOT() public view override returns (IMessageRoot) {
        return messageRoot;
    }

    // solhint-disable-next-line func-name-mixedcase
    function ASSET_ROUTER() public view override returns (IAssetRouterBase) {
        return assetRouter;
    }

    function _assetRouter() internal view override returns (IAssetRouterBase) {
        return assetRouter;
    }

    constructor(address _owner, address _bridgehub) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = IL1Bridgehub(_bridgehub);
        L1_CHAIN_ID = block.chainid;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @notice Sets the addresses of the message root and asset router by querying the bridgehub.
    /// @dev Called after deployment once the dependent contracts are registered on the bridgehub.
    function setAddresses() external onlyOwner {
        messageRoot = BRIDGEHUB.messageRoot();
        assetRouter = BRIDGEHUB.assetRouter();
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    /// @param _assetId the assetId of the chain's CTM
    /// @param _data the data for the recovery.
    /// @param _depositSender the address of the entity that initiated the deposit.
    // slither-disable-next-line locked-ether
    function bridgeConfirmTransferResult(
        uint256,
        TxStatus _txStatus,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable requireZeroValue(msg.value) onlyAssetRouter {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));
        uint256 chainId = bridgehubBurnData.chainId;

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeConfirmTransferResult(
            chainId,
            _txStatus
        );

        IChainTypeManager(ctm).forwardedBridgeConfirmTransferResult({
            _chainId: chainId,
            _txStatus: _txStatus,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        if (_txStatus == TxStatus.Failure) {
            uint256 failedMigrationNum = migrationNumber[chainId];
            require(
                failedMigrationNum == MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
                MigrationNumberMismatch(MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, failedMigrationNum)
            );
            migrationNumber[chainId] = failedMigrationNum - 1;
            // Reset migration interval since the L1 -> SL migration failed.
            // This prevents stale migrateToGWBatchNumber from affecting settlement layer validation.
            delete _migrationInterval[chainId][failedMigrationNum];
        }

        isMigrationInProgress[chainId] = false;

        IZKChain(zkChain).forwardedBridgeConfirmTransferResult({
            _chainId: chainId,
            _txStatus: _txStatus,
            _assetInfo: _assetId,
            _originalCaller: _depositSender,
            _chainData: bridgehubBurnData.chainData
        });
    }

    function _setMigrationInProgressOnL1(uint256 _chainId) internal override {
        isMigrationInProgress[_chainId] = true;
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT LAYER VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets a historical migration interval for a chain.
    /// @dev Only callable by owner. Used to set legacy GW migration data for chains that used the old GW.
    /// @param _chainId The ID of the chain.
    /// @param _migrationNumber The migration number to set (0 for legacy GW data).
    /// @param _interval The migration interval data.
    function setHistoricalMigrationInterval(
        uint256 _chainId,
        uint256 _migrationNumber,
        MigrationInterval calldata _interval
    ) external onlyOwner {
        require(_migrationNumber == 0, MigrationNumberMismatch(0, _migrationNumber));
        require(!_interval.isActive, MigrationIntervalNotSet());
        uint256 legacyGwChainId = IMessageRoot(_messageRoot()).ERA_GATEWAY_CHAIN_ID();
        require(
            _interval.settlementLayerChainId == legacyGwChainId,
            HistoricalSettlementLayerMismatch(legacyGwChainId, _interval.settlementLayerChainId)
        );
        require(_interval.migrateFromGWBatchNumber > _interval.migrateToGWBatchNumber, MigrationIntervalInvalid());
        require(
            _interval.settlementLayerBatchUpperBound > _interval.settlementLayerBatchLowerBound,
            MigrationIntervalInvalid()
        );
        _migrationInterval[_chainId][_migrationNumber] = _interval;
    }

    /// @notice Validates if a claimed settlement layer is valid for a given chain and batch number.
    /// @dev Used by MessageRoot to validate that proofs claim the correct settlement layer.
    /// @dev Checks all migration intervals for the chain, including legacy GW data (migration number 0).
    /// @param _chainId The ID of the chain.
    /// @param _batchNumber The batch number to check.
    /// @param _claimedSettlementLayer The settlement layer chain ID claimed in the proof.
    /// @param _claimedSettlementLayerBatchNumber The batch number claimed in the settlement layer.
    /// @return True if the claimed settlement layer is valid for this chain and batch.
    function isValidSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _claimedSettlementLayer,
        uint256 _claimedSettlementLayerBatchNumber
    ) external view returns (bool) {
        // Check all migration intervals for this chain (including legacy GW at index 0)
        // We iterate from 0 to current migration number to find which interval contains this batch
        uint256 currentMigrationNum = migrationNumber[_chainId];
        // IMPORTANT: this method is safe only while migrations are limited to one round-trip (L1->SL->L1).
        // If this was not the case, the chain admin would be able to migrate back and forth multiple times,
        // causing the function to run out of gas and blocking withdrawals, which would violate stage1-compatibility requirements.
        require(currentMigrationNum <= MAX_ALLOWED_NUMBER_OF_MIGRATIONS, IteratedMigrationsNotSupported());

        for (uint256 i = 0; i <= currentMigrationNum; ++i) {
            MigrationInterval memory interval = _migrationInterval[_chainId][i];

            // Skip uninitialized intervals
            if (interval.settlementLayerChainId == 0) {
                continue;
            }

            if (_batchNumber <= interval.migrateToGWBatchNumber) {
                // Batch is before migration to SL, so it was on L1 during this interval.
                return _claimedSettlementLayer == _l1ChainId();
            }

            if (interval.isActive) {
                // Batch is after migration to SL, and the chain hasn't returned yet, so it must be on the settlement layer.
                return
                    _claimedSettlementLayer == interval.settlementLayerChainId &&
                    _claimedSettlementLayerBatchNumber >= interval.settlementLayerBatchLowerBound;
            }

            // Batch is after migration to SL
            if (_batchNumber <= interval.migrateFromGWBatchNumber) {
                // Batch is in the SL range: (migrateToSL, migrateFromSL] or chain hasn't returned.
                // Also verify the claimed SL batch number falls within the recorded bounds.
                // For active intervals, the upper bound is not yet known so we only check the lower bound.
                return
                    _claimedSettlementLayer == interval.settlementLayerChainId &&
                    _claimedSettlementLayerBatchNumber >= interval.settlementLayerBatchLowerBound &&
                    _claimedSettlementLayerBatchNumber <= interval.settlementLayerBatchUpperBound;
            }

            // Batch is after migration back from SL, continue to check next interval
        }

        // Default: batch was on L1 (no matching SL interval found)
        return _claimedSettlementLayer == _l1ChainId();
    }

    /// @notice Returns the migration interval for a chain at a specific migration number.
    /// @param _chainId The ID of the chain.
    /// @param _migrationNumber The migration number (0 for legacy GW, 1+ for regular migrations).
    /// @return interval The migration interval data.
    function migrationInterval(
        uint256 _chainId,
        uint256 _migrationNumber
    ) external view returns (MigrationInterval memory interval) {
        return _migrationInterval[_chainId][_migrationNumber];
    }

    function _recordMigrationToSL(
        uint256 _chainId,
        uint256 _settlementChainId,
        uint256 _batchNumber,
        uint256 _newMigrationNum
    ) internal override {
        if (_settlementChainId == _l1ChainId()) {
            revert SettlementLayerMustNotBeL1();
        }
        require(
            _newMigrationNum == MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
            MigrationNumberMismatch(MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, _newMigrationNum)
        );
        uint256 slBatchLowerBound = IMessageRoot(_messageRoot()).currentChainBatchNumber(_settlementChainId);
        _migrationInterval[_chainId][_newMigrationNum] = MigrationInterval({
            migrateToGWBatchNumber: _batchNumber,
            migrateFromGWBatchNumber: 0,
            settlementLayerBatchLowerBound: slBatchLowerBound,
            settlementLayerBatchUpperBound: 0,
            settlementLayerChainId: _settlementChainId,
            isActive: true
        });
    }

    /// @notice Records that a chain has returned from a settlement layer back to L1.
    /// @dev The `settlementLayerBatchUpperBound` is set to the settlement layer's current batch number at the time
    /// this function is called (during `bridgeMint` on L1). This is not a perfect upper bound — the exact settlement
    /// layer batch number is not trivially available, so we use the current value at finalization time. The sooner the
    /// migration is finalized, the more precise this value is, since the settlement layer continues producing batches
    /// in the meantime. A more precise solution will be introduced in future releases.
    function _recordMigrationFromSL(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _newMigrationNum
    ) internal override {
        require(
            _newMigrationNum == MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
            MigrationNumberMismatch(MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1, _newMigrationNum)
        );
        MigrationInterval storage interval = _migrationInterval[_chainId][MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER];
        require(interval.isActive, MigrationIntervalNotSet());
        interval.migrateFromGWBatchNumber = _batchNumber;
        interval.settlementLayerBatchUpperBound = IMessageRoot(_messageRoot()).currentChainBatchNumber(
            interval.settlementLayerChainId
        );
        interval.isActive = false;
    }
}
