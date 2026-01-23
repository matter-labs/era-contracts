// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehubBase, BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData} from "../bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";

import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "../../common/Config.sol";
import {IncorrectChainAssetId, IncorrectSender, MigrationNotToL1, MigrationNumberAlreadySet, MigrationNumberMismatch, NotSystemContext, OnlyChain, SLHasDifferentCTM, ZKChainNotRegistered, IteratedMigrationsNotSupported} from "../bridgehub/L1BridgehubErrors.sol";
import {ChainIdNotRegistered, MigrationPaused, NotAssetRouter} from "../../common/L1ContractErrors.sol";
import {MigrationInterval} from "./IChainAssetHandler.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {AssetHandlerModifiers} from "../../bridge/interfaces/AssetHandlerModifiers.sol";
import {IChainAssetHandler} from "./IChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
abstract contract ChainAssetHandlerBase is
    IChainAssetHandler,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AssetHandlerModifiers
{
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _l1ChainId() internal view virtual returns (uint256);

    function _bridgehub() internal view virtual returns (IL1Bridgehub);

    function _messageRoot() internal view virtual returns (IMessageRoot);

    function _assetRouter() internal view virtual returns (IAssetRouterBase);

    /// @notice Used to pause the migrations of chains. Used for upgrades.
    bool public migrationPaused;

    /// @dev The assetId of the ETH.
    /// @dev Kept here for storage layout compatibility with previous versions.
    bytes32 internal DEPRECATED_ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    /// @dev Kept here for storage layout compatibility with previous versions.
    uint256 internal DEPRECATED_L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    /// @dev Kept here for storage layout compatibility with previous versions.
    IL1Bridgehub internal DEPRECATED_BRIDGEHUB;

    /// @dev The message root contract.
    /// @dev Kept here for storage layout compatibility with previous versions.
    IMessageRoot internal DEPRECATED_MESSAGE_ROOT;

    /// @dev The asset router contract.
    /// @dev Kept here for storage layout compatibility with previous versions.
    IAssetRouterBase internal DEPRECATED_ASSET_ROUTER;

    /// @notice Used to track the number of times each chain has migrated.
    /// NOTE: this mapping may be deprecated in the future, don't rely on it!
    mapping(uint256 chainId => uint256 migrationNumber) public migrationNumber;

    /// @notice The chain ID of the legacy Gateway. Used for settlement layer validation.
    uint256 public constant LEGACY_GW_CHAIN_ID = 9075;

    /// @notice The batch range where LEGACY_GW_CHAIN_ID is always allowed as settlement layer.
    /// @dev This represents the historical period when some chains were on the legacy GW.
    /// @dev These values will be set to the actual range before V31 deployment (GW will be shut down first).
    /// TODO: Set actual values.
    uint256 public constant LEGACY_GW_BATCH_FROM = 0;
    uint256 public constant LEGACY_GW_BATCH_TO = 0;

    /// @notice Tracks migration batch numbers for chains that migrated to Gateway.
    /// @dev Used to validate that settlement layer claims match the batch number.
    mapping(uint256 chainId => MigrationInterval) public migrationInterval;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[42] private __gap;

    /// @notice Only the asset router can call.
    modifier onlyAssetRouter() {
        if (msg.sender != address(_assetRouter())) {
            revert NotAssetRouter(msg.sender, address(_assetRouter()));
        }
        _;
    }

    /// @notice Only when migrations are not paused.
    modifier whenMigrationsNotPaused() {
        if (migrationPaused) {
            revert MigrationPaused();
        }
        _;
    }

    modifier onlySystemContext() {
        if (msg.sender != L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR) {
            revert NotSystemContext(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            V31 Upgrade
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks that the message sender is the specified ZK Chain.
    /// @param _chainId The ID of the chain that is required to be the caller.
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != IBridgehubBase(_bridgehub()).getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, IBridgehubBase(_bridgehub()).getZKChain(_chainId));
        }
        _;
    }

    /// @notice Sets the migration number for a chain on the Gateway when the chain's DiamondProxy upgrades.
    function setMigrationNumberForV31(uint256 _chainId) external onlyChain(_chainId) {
        require(migrationNumber[_chainId] == 0, MigrationNumberAlreadySet());
        bool isOnThisSettlementLayer = block.chainid == IBridgehubBase(_bridgehub()).settlementLayer(_chainId);
        bool shouldIncrementMigrationNumber = (isOnThisSettlementLayer && block.chainid != _l1ChainId()) ||
            (!isOnThisSettlementLayer && block.chainid == _l1ChainId());
        /// Note we don't increment the migration number if the chain migrated to GW and back to L1 previously.
        if (shouldIncrementMigrationNumber) {
            migrationNumber[_chainId] = 1;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Chain migration
    //////////////////////////////////////////////////////////////*/

    /// @notice IL1AssetHandler interface, used to migrate (transfer) a chain to the settlement layer.
    /// @param _settlementChainId the chainId of the settlement chain, i.e. where the message and the migrating chain is sent.
    /// @param _assetId the assetId of the migrating chain's CTM
    /// @param _originalCaller the message sender initiated a set of calls that leads to bridge burn
    /// @param _data the data for the migration
    // slither-disable-next-line locked-ether
    function bridgeBurn(
        uint256 _settlementChainId,
        uint256 _l2MsgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes calldata _data
    )
        external
        payable
        override
        requireZeroValue(_l2MsgValue + msg.value)
        onlyAssetRouter
        whenNotPaused
        whenMigrationsNotPaused
        returns (bytes memory bridgehubMintData)
    {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));
        require(
            _assetId == IBridgehubBase(_bridgehub()).ctmAssetIdFromChainId(bridgehubBurnData.chainId),
            IncorrectChainAssetId(
                _assetId,
                IBridgehubBase(_bridgehub()).ctmAssetIdFromChainId(bridgehubBurnData.chainId)
            )
        );
        address zkChain = IBridgehubBase(_bridgehub()).getZKChain(bridgehubBurnData.chainId);

        bytes memory ctmMintData;
        // to avoid stack too deep
        {
            address ctm;
            (zkChain, ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeBurnSetSettlementLayer(
                bridgehubBurnData.chainId,
                _settlementChainId
            );

            if (zkChain == address(0)) {
                revert ZKChainNotRegistered();
            }
            if (_originalCaller != IZKChain(zkChain).getAdmin()) {
                revert IncorrectSender(_originalCaller, IZKChain(zkChain).getAdmin());
            }

            ctmMintData = IChainTypeManager(ctm).forwardedBridgeBurn(
                bridgehubBurnData.chainId,
                bridgehubBurnData.ctmData
            );

            // For security reasons, chain migration is temporarily restricted to settlement layers with the same CTM
            if (
                _settlementChainId != _l1ChainId() &&
                IBridgehubBase(_bridgehub()).chainTypeManager(_settlementChainId) != ctm
            ) {
                revert SLHasDifferentCTM();
            }

            if (block.chainid != _l1ChainId()) {
                require(_settlementChainId == _l1ChainId(), MigrationNotToL1());
            }
            _setMigrationInProgressOnL1(bridgehubBurnData.chainId);
        }
        bytes memory chainMintData = IZKChain(zkChain).forwardedBridgeBurn(
            _settlementChainId == _l1ChainId()
                ? L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS
                : IBridgehubBase(_bridgehub()).getZKChain(_settlementChainId),
            _originalCaller,
            bridgehubBurnData.chainData
        );
        // Iterated migrations are not supported to avoid asset migration number complications related to token balance migration.
        // This means a chain can migrate to GW and back to L1 but only once.
        require(migrationNumber[bridgehubBurnData.chainId] < 2, IteratedMigrationsNotSupported());
        ++migrationNumber[bridgehubBurnData.chainId];

        uint256 batchNumber = IMessageRoot(_messageRoot()).currentChainBatchNumber(bridgehubBurnData.chainId);

        // Track migration interval for settlement layer validation.
        // When migrating FROM L1 TO a settlement layer, record the last L1 batch number and the SL chain ID.
        if (block.chainid == _l1ChainId() && _settlementChainId != _l1ChainId()) {
            migrationInterval[bridgehubBurnData.chainId].migrateToSLBatchNumber = batchNumber;
            migrationInterval[bridgehubBurnData.chainId].settlementLayerChainId = _settlementChainId;
        }

        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgehubBurnData.chainId,
            baseTokenAssetId: IBridgehubBase(_bridgehub()).baseTokenAssetId(bridgehubBurnData.chainId),
            batchNumber: batchNumber,
            ctmData: ctmMintData,
            chainData: chainMintData,
            migrationNumber: migrationNumber[bridgehubBurnData.chainId]
        });
        bridgehubMintData = abi.encode(bridgeMintStruct);

        emit MigrationStarted(bridgehubBurnData.chainId, _assetId, _settlementChainId);
    }

    function _setMigrationInProgressOnL1(uint256 _chainId) internal virtual {}

    /// @dev IL1AssetHandler interface, used to receive a chain on the settlement layer.
    /// @param _assetId the assetId of the chain's CTM
    /// @param _bridgehubMintData the data for the mint
    // slither-disable-next-line locked-ether
    function bridgeMint(
        uint256, // originChainId
        bytes32 _assetId,
        bytes calldata _bridgehubMintData
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenNotPaused whenMigrationsNotPaused {
        BridgehubMintCTMAssetData memory bridgehubMintData = abi.decode(
            _bridgehubMintData,
            (BridgehubMintCTMAssetData)
        );

        uint256 currentMigrationNumber = migrationNumber[bridgehubMintData.chainId];
        /// If we are not migrating for the first time, we check that the migration number is correct.
        if (currentMigrationNumber != 0 && block.chainid == _l1ChainId()) {
            require(
                currentMigrationNumber + 1 == bridgehubMintData.migrationNumber,
                MigrationNumberMismatch(currentMigrationNumber + 1, bridgehubMintData.migrationNumber)
            );
        }
        migrationNumber[bridgehubMintData.chainId] = bridgehubMintData.migrationNumber;

        // Track migration interval for settlement layer validation.
        // When migrating FROM settlement layer BACK TO L1, record the last SL batch number.
        // This happens when migrationNumber is 2 (first migration was L1->SL, second is SL->L1).
        if (block.chainid == _l1ChainId() && bridgehubMintData.migrationNumber == 2) {
            migrationInterval[bridgehubMintData.chainId].migrateFromSLBatchNumber = bridgehubMintData.batchNumber;
        }

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeMint(
            _assetId,
            bridgehubMintData.chainId,
            bridgehubMintData.baseTokenAssetId
        );

        bool contractAlreadyDeployed = zkChain != address(0);
        if (!contractAlreadyDeployed) {
            zkChain = IChainTypeManager(ctm).forwardedBridgeMint(bridgehubMintData.chainId, bridgehubMintData.ctmData);
            if (zkChain == address(0)) {
                revert ChainIdNotRegistered(bridgehubMintData.chainId);
            }
            // We want to allow any chain to be migrated,
            IBridgehubBase(_bridgehub()).registerNewZKChain(bridgehubMintData.chainId, zkChain, false);
            IMessageRoot(_messageRoot()).addNewChain(bridgehubMintData.chainId, bridgehubMintData.batchNumber);
        } else {
            // Note, that here we rely on the correctness of the provided data.
            // A malicious settlement layer could provide invalid values here.
            // To support untrusted CTMs, we would need to at the very least enforce
            // that the `v31UpgradeChainBatchNumber` is not in conflict with the existing values.
            IMessageRoot(_messageRoot()).setMigratingChainBatchRoot(
                bridgehubMintData.chainId,
                bridgehubMintData.batchNumber
            );
        }

        IZKChain(zkChain).forwardedBridgeMint(bridgehubMintData.chainData, contractAlreadyDeployed);

        emit MigrationFinalized(bridgehubMintData.chainId, _assetId, zkChain);
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT LAYER VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates if a claimed settlement layer is valid for a given chain and batch number.
    /// @dev Used by MessageRoot to validate that proofs claim the correct settlement layer.
    /// @dev Special case: for batches in [LEGACY_GW_BATCH_FROM, LEGACY_GW_BATCH_TO], both L1 and LEGACY_GW are valid.
    /// @param _chainId The ID of the chain.
    /// @param _batchNumber The batch number to check.
    /// @param _claimedSettlementLayer The settlement layer chain ID claimed in the proof.
    /// @return True if the claimed settlement layer is valid for this chain and batch.
    function isValidSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _claimedSettlementLayer
    ) external view returns (bool) {
        // For batches in the legacy GW range, BOTH L1 and LEGACY_GW are valid.
        if (_batchNumber >= LEGACY_GW_BATCH_FROM && _batchNumber <= LEGACY_GW_BATCH_TO) {
            return _claimedSettlementLayer == _l1ChainId() || _claimedSettlementLayer == LEGACY_GW_CHAIN_ID;
        }

        MigrationInterval memory interval = migrationInterval[_chainId];

        // Chain has a migration interval set - use it
        if (interval.migrateToSLBatchNumber != 0) {
            // Chain migrated to SL but hasn't returned yet
            if (interval.migrateFromSLBatchNumber == 0) {
                if (_batchNumber <= interval.migrateToSLBatchNumber) {
                    // Batches up to and including migrateToSLBatchNumber were on L1
                    return _claimedSettlementLayer == _l1ChainId();
                }
                // Batches after migrateToSLBatchNumber are on the settlement layer
                return _claimedSettlementLayer == interval.settlementLayerChainId;
            }

            // Chain migrated to SL and back to L1
            if (_batchNumber <= interval.migrateToSLBatchNumber) {
                // Batches up to migrateToSLBatchNumber were on L1
                return _claimedSettlementLayer == _l1ChainId();
            } else if (_batchNumber <= interval.migrateFromSLBatchNumber) {
                // Batches in (migrateToSLBatchNumber, migrateFromSLBatchNumber] were on SL
                return _claimedSettlementLayer == interval.settlementLayerChainId;
            } else {
                // Batches after migrateFromSLBatchNumber are back on L1
                return _claimedSettlementLayer == _l1ChainId();
            }
        }

        // Default: only L1 is valid
        return _claimedSettlementLayer == _l1ChainId();
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses migration functions.
    function pauseMigration() external onlyOwner {
        migrationPaused = true;
    }

    /// @notice Unpauses migration functions.
    function unpauseMigration() external onlyOwner {
        migrationPaused = false;
    }

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
