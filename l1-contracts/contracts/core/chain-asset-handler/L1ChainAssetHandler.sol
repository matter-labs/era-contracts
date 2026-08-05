// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {
    ETH_TOKEN_ADDRESS,
    MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
    MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
    MAX_ALLOWED_NUMBER_OF_MIGRATIONS
} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {TxStatus} from "../../common/Messaging.sol";
import {BridgehubBurnCTMAssetData, IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetHandler} from "../../bridge/interfaces/IL1AssetHandler.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IMessageRootBase} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";
import {IL1ChainAssetHandler} from "./IL1ChainAssetHandler.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IL2ChainAssetHandler} from "./IL2ChainAssetHandler.sol";
import {ChainNotReadyForMigration, ZKChainNotRegistered} from "../bridgehub/L1BridgehubErrors.sol";
import {CTMNotRegistered} from "../../common/L1ContractErrors.sol";
import {
    MigrationIntervalInvalid,
    MigrationIntervalNotSet,
    MigrationNumberMismatch,
    SettlementLayerMustNotBeL1,
    IteratedMigrationsNotSupported,
    HistoricalSettlementLayerMismatch
} from "../bridgehub/L1BridgehubErrors.sol";
import {MigrationInterval} from "./IChainAssetHandler.sol";
import {IL1MessageRoot} from "../message-root/IL1MessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 deployment of the chain asset handler. See {protocol-docs/chain-lifecycle.md#settlement-layer-migration-chainassethandler}.
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase, IL1AssetHandler, IL1ChainAssetHandler {
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
    IMessageRootBase internal messageRoot;

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
    function _messageRoot() internal view override returns (IMessageRootBase) {
        return messageRoot;
    }

    // solhint-disable-next-line func-name-mixedcase
    function MESSAGE_ROOT() public view override returns (IMessageRootBase) {
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

    /// @inheritdoc IL1AssetHandler
    /// @dev Undoes a failed migration of a chain. Deliberately NOT gated by `whenMigrationsEnabled`:
    /// it only ever returns a chain back to settling on L1.
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

        // Note: _chainId is the settlement layer chain (e.g. gateway) where the migration tx was proven,
        // while bridgehubBurnData.chainId is the chain being migrated. These are intentionally different.

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeConfirmTransferResult(
            chainId,
            _txStatus
        );

        require(zkChain != address(0), ZKChainNotRegistered());
        require(ctm != address(0), CTMNotRegistered());

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

    /// @inheritdoc IL1ChainAssetHandler
    function isReadyForMigration(uint256 _chainId) public view returns (bool) {
        bytes32 baseAssetId = BRIDGEHUB.baseTokenAssetId(_chainId);
        address zkChain = BRIDGEHUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
        IL1AssetRouter l1AssetRouter = IL1AssetRouter(address(_assetRouter()));
        IL1NativeTokenVault nativeTokenVault = IL1NativeTokenVault(address(l1AssetRouter.nativeTokenVault()));

        return
            // The chain must have version higher than v31.
            !IL1MessageRoot(address(_messageRoot())).isPreV31(_chainId) &&
            // The chain's base token must be registered in the NTV, as otherwise L1->L2 base-token
            // deposits (which the destination NTV relies on) would not work.
            nativeTokenVault.tokenAddress(baseAssetId) != address(0) &&
            // The chain's base token must support `totalSupply()`, which is the case
            // for all chains except for pre-v31 ZKsync OS ones (their value is backfilled
            // before the v31 upgrade). Otherwise token balance migration may not work.
            IZKChain(zkChain).baseTokenSupportsTotalSupply();
    }

    /// @inheritdoc IL1ChainAssetHandler
    function requestPauseDepositsForChainOnGateway(uint256 _chainId) external {
        require(msg.sender == BRIDGEHUB.getZKChain(_chainId), ZKChainNotRegistered());
        uint256 settlementLayer = BRIDGEHUB.settlementLayer(_chainId);
        require(settlementLayer != block.chainid, SettlementLayerMustNotBeL1());
        // slither-disable-next-line unused-return
        IMailbox(BRIDGEHUB.getZKChain(settlementLayer)).requestL2ServiceTransaction(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeCall(IL2ChainAssetHandler.requestPauseDepositsForChainOnGateway, (_chainId))
        );
    }

    function _setMigrationInProgressOnL1(uint256 _chainId) internal override {
        require(isReadyForMigration(_chainId), ChainNotReadyForMigration(_chainId));
        isMigrationInProgress[_chainId] = true;
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT LAYER VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1ChainAssetHandler
    function setHistoricalMigrationInterval(
        uint256 _chainId,
        uint256 _migrationNumber,
        MigrationInterval calldata _interval
    ) external onlyOwner {
        require(_migrationNumber == 0, MigrationNumberMismatch(0, _migrationNumber));
        require(!_interval.isActive, MigrationIntervalNotSet());
        uint256 legacyGwChainId = IL1MessageRoot(address(_messageRoot())).ERA_GATEWAY_CHAIN_ID();
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

    /// @inheritdoc IL1ChainAssetHandler
    /// @dev Used by MessageRoot to validate that proofs claim the correct settlement layer; checks
    /// all migration intervals for the chain, including legacy GW data (migration number 0).
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

    /// @inheritdoc IL1ChainAssetHandler
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
        uint256 slBatchLowerBound = _messageRoot().currentChainBatchNumber(_settlementChainId);
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
    /// @dev The recorded `settlementLayerBatchUpperBound` is only approximate — see its doc on
    /// {MigrationInterval}.
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
        interval.settlementLayerBatchUpperBound = _messageRoot().currentChainBatchNumber(
            interval.settlementLayerChainId
        );
        interval.isActive = false;
    }
}
