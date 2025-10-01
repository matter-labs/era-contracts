// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData, IBridgehub} from "./IBridgehub.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";

import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "../common/Config.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {IncorrectChainAssetId, IncorrectSender, MigrationNotToL1, MigrationNumberAlreadySet, MigrationNumberMismatch, NotSystemContext, OnlyAssetTrackerOrChain, OnlyChain, SLHasDifferentCTM, ZKChainNotRegistered} from "./L1BridgehubErrors.sol";
import {ChainIdNotRegistered, MigrationPaused, NotAssetRouter, NotL1} from "../common/L1ContractErrors.sol";
import {GW_ASSET_TRACKER, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

import {AssetHandlerModifiers} from "../bridge/interfaces/AssetHandlerModifiers.sol";
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
                            IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view virtual returns (bytes32);

    function _l1ChainId() internal view virtual returns (uint256);

    function _bridgehub() internal view virtual returns (IBridgehub);

    function _messageRoot() internal view virtual returns (IMessageRoot);

    function _assetRouter() internal view virtual returns (address);

    function _assetTracker() internal view virtual returns (address);

    /// @notice used to pause the migrations of chains. Used for upgrades.
    bool public migrationPaused;

    /// @notice used to track the number of times each chain has migrated.
    mapping(uint256 chainId => uint256 migrationNumber) internal migrationNumber;

    /// @notice Only the asset router can call.
    modifier onlyAssetRouter() {
        if (msg.sender != _assetRouter()) {
            revert NotAssetRouter(msg.sender, _assetRouter());
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

    /// @notice Only when the contract is deployed on L1.
    modifier onlyL1() {
        if (_l1ChainId() != block.chainid) {
            revert NotL1(_l1ChainId(), block.chainid);
        }
        _;
    }

    modifier onlyAssetTrackerOrChain(uint256 _chainId) {
        if (msg.sender != _assetTracker() && msg.sender != _bridgehub().getZKChain(_chainId)) {
            revert OnlyAssetTrackerOrChain(msg.sender, _chainId);
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
                            Getters
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the migration number for a chain.
    function getMigrationNumber(uint256 _chainId) external view returns (uint256) {
        // onlyAssetTrackerOrChain(_chainId) returns (uint256) {
        return migrationNumber[_chainId];
    }

    /*//////////////////////////////////////////////////////////////
                            V30 Upgrade
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks that the message sender is the specified ZK Chain.
    /// @param _chainId The ID of the chain that is required to be the caller.
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != _bridgehub().getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, _bridgehub().getZKChain(_chainId));
        }
        _;
    }

    /// @notice Sets the migration number for a chain on the Gateway when the chain's DiamondProxy upgrades.
    function setMigrationNumberForV30(uint256 _chainId) external onlyChain(_chainId) {
        require(migrationNumber[_chainId] == 0, MigrationNumberAlreadySet());
        bool isOnThisSettlementLayer = block.chainid == _bridgehub().settlementLayer(_chainId);
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

    error UnprocessedDepositsNotProcessed();

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
        whenMigrationsNotPaused
        returns (bytes memory bridgehubMintData)
    {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));
        require(
            _assetId == _bridgehub().ctmAssetIdFromChainId(bridgehubBurnData.chainId),
            IncorrectChainAssetId(_assetId, _bridgehub().ctmAssetIdFromChainId(bridgehubBurnData.chainId))
        );
        address zkChain = _bridgehub().getZKChain(bridgehubBurnData.chainId);

        bytes memory ctmMintData;
        // to avoid stack too deep
        {
            address ctm;
            (zkChain, ctm) = _bridgehub().forwardedBridgeBurnSetSettlementLayer(
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
            if (_settlementChainId != _l1ChainId() && _bridgehub().chainTypeManager(_settlementChainId) != ctm) {
                revert SLHasDifferentCTM();
            }

            if (block.chainid != _l1ChainId()) {
                require(_settlementChainId == _l1ChainId(), MigrationNotToL1());
                require(
                    GW_ASSET_TRACKER.unprocessedDeposits(bridgehubBurnData.chainId) == 0,
                    UnprocessedDepositsNotProcessed()
                );
            }
        }
        bytes memory chainMintData = IZKChain(zkChain).forwardedBridgeBurn(
            _settlementChainId == _l1ChainId()
                ? L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS
                : _bridgehub().getZKChain(_settlementChainId),
            _originalCaller,
            bridgehubBurnData.chainData
        );
        ++migrationNumber[bridgehubBurnData.chainId];

        uint256 batchNumber = _messageRoot().currentChainBatchNumber(bridgehubBurnData.chainId);

        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgehubBurnData.chainId,
            baseTokenAssetId: _bridgehub().baseTokenAssetId(bridgehubBurnData.chainId),
            batchNumber: batchNumber,
            ctmData: ctmMintData,
            chainData: chainMintData,
            migrationNumber: migrationNumber[bridgehubBurnData.chainId],
            v30UpgradeChainBatchNumber: _messageRoot().v30UpgradeChainBatchNumber(bridgehubBurnData.chainId)
        });
        bridgehubMintData = abi.encode(bridgeMintStruct);

        emit MigrationStarted(bridgehubBurnData.chainId, _assetId, _settlementChainId);
    }

    /// @dev IL1AssetHandler interface, used to receive a chain on the settlement layer.
    /// @param _assetId the assetId of the chain's CTM
    /// @param _bridgehubMintData the data for the mint
    // slither-disable-next-line locked-ether
    function bridgeMint(
        uint256, // originChainId
        bytes32 _assetId,
        bytes calldata _bridgehubMintData
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenMigrationsNotPaused {
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

        (address zkChain, address ctm) = _bridgehub().forwardedBridgeMint(
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
            _bridgehub().registerNewZKChain(bridgehubMintData.chainId, zkChain, false);
            _messageRoot().addNewChain(bridgehubMintData.chainId, bridgehubMintData.batchNumber);
        } else {
            _messageRoot().setMigratingChainBatchRoot(
                bridgehubMintData.chainId,
                bridgehubMintData.batchNumber,
                bridgehubMintData.v30UpgradeChainBatchNumber
            );
        }

        IZKChain(zkChain).forwardedBridgeMint(bridgehubMintData.chainData, contractAlreadyDeployed);

        emit MigrationFinalized(bridgehubMintData.chainId, _assetId, zkChain);
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    // / @param _chainId the chainId of the chain
    /// @param _assetId the assetId of the chain's CTM
    /// @param _data the data for the recovery.
    /// @param _depositSender the address of the entity that initiated the deposit.
    // slither-disable-next-line locked-ether
    function bridgeRecoverFailedTransfer(
        uint256,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter onlyL1 {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));

        (address zkChain, address ctm) = _bridgehub().forwardedBridgeRecoverFailedTransfer(bridgehubBurnData.chainId);

        IChainTypeManager(ctm).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        --migrationNumber[bridgehubBurnData.chainId];

        IZKChain(zkChain).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _originalCaller: _depositSender,
            _chainData: bridgehubBurnData.chainData
        });
    }

    /*//////////////////////////////////////////////////////////////
                            L2 functions
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is called at the start of each batch.
    function setSettlementLayerChainId(
        uint256 _previousSettlementLayerChainId,
        uint256 _currentSettlementLayerChainId
    ) external onlySystemContext {
        if (_previousSettlementLayerChainId == 0 && _currentSettlementLayerChainId == _l1ChainId()) {
            /// For the initial call if we are settling on L1, we return, as there is no real migration.
            return;
        }
        if (_previousSettlementLayerChainId != _currentSettlementLayerChainId) {
            ++migrationNumber[block.chainid];
        }
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
}
