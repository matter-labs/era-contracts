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
import {ChainBatchRootNotSet, NextChainBatchRootAlreadySet, ZKChainNotRegistered, SLHasDifferentCTM, IncorrectChainAssetId, IncorrectSender, MigrationNumberAlreadySet, MigrationNumberMismatch, NotSystemContext, OnlyAssetTrackerOrChain, OnlyChain} from "./L1BridgehubErrors.sol";
import {ChainIdNotRegistered, MigrationPaused, NotL1, NotAssetRouter} from "../common/L1ContractErrors.sol";
import {GW_ASSET_TRACKER_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

import {AssetHandlerModifiers} from "../bridge/interfaces/AssetHandlerModifiers.sol";
import {IChainAssetHandler} from "./IChainAssetHandler.sol";
import {IGWAssetTracker} from "../bridge/asset-tracker/IGWAssetTracker.sol";
import {IL1Nullifier} from "../bridge/interfaces/IL1Nullifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
contract ChainAssetHandler is
    IChainAssetHandler,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AssetHandlerModifiers
{
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice The chain id of the L1.
    uint256 internal immutable L1_CHAIN_ID;

    IBridgehub internal immutable BRIDGE_HUB;

    /// @notice The message root contract.
    IMessageRoot internal immutable MESSAGE_ROOT;

    /// @notice The asset router contract.
    address internal immutable ASSET_ROUTER;

    address internal immutable ASSET_TRACKER;

    IL1Nullifier internal immutable L1_NULLIFIER;

    /// @notice used to pause the migrations of chains. Used for upgrades.
    bool public migrationPaused;

    /// @notice used to track the number of times each chain has migrated.
    mapping(uint256 chainId => uint256 migrationNumber) internal migrationNumber;

    /// @notice Only the asset router can call.
    modifier onlyAssetRouter() {
        if (msg.sender != ASSET_ROUTER) {
            revert NotAssetRouter(msg.sender, ASSET_ROUTER);
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
        if (L1_CHAIN_ID != block.chainid) {
            revert NotL1(L1_CHAIN_ID, block.chainid);
        }
        _;
    }

    modifier onlyAssetTrackerOrChain(uint256 _chainId) {
        if (msg.sender != ASSET_TRACKER && msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
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

    /// @notice to avoid parity hack
    constructor(
        uint256 _l1ChainId,
        address _owner,
        IBridgehub _bridgehub,
        address _assetRouter,
        address _assetTracker,
        IMessageRoot _messageRoot,
        address _l1Nullifier
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ASSET_ROUTER = _assetRouter;
        MESSAGE_ROOT = _messageRoot;
        ASSET_TRACKER = _assetTracker;
        L1_NULLIFIER = IL1Nullifier(_l1Nullifier);
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
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
        if (msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, BRIDGE_HUB.getZKChain(_chainId));
        }
        _;
    }

    /// @notice Sets the migration number for a chain on the Gateway when the chain's DiamondProxy upgrades.
    function setMigrationNumberForV30(uint256 _chainId) external onlyChain(_chainId) {
        require(migrationNumber[_chainId] == 0, MigrationNumberAlreadySet());
        bool isOnThisSettlementLayer = block.chainid == BRIDGE_HUB.settlementLayer(_chainId);
        bool shouldIncrementMigrationNumber = (isOnThisSettlementLayer && block.chainid != L1_CHAIN_ID) || (!isOnThisSettlementLayer && block.chainid == L1_CHAIN_ID);
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
        whenMigrationsNotPaused
        returns (bytes memory bridgehubMintData)
    {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));
        require(
            _assetId == BRIDGE_HUB.ctmAssetIdFromChainId(bridgehubBurnData.chainId),
            IncorrectChainAssetId(_assetId, BRIDGE_HUB.ctmAssetIdFromChainId(bridgehubBurnData.chainId))
        );
        address zkChain = BRIDGE_HUB.getZKChain(bridgehubBurnData.chainId);

        // We set the legacy shared bridge address on the gateway asset tracker to allow for L2->L1 asset withdrawals via the L2AssetRouter.
        if (block.chainid == L1_CHAIN_ID) {
            bytes memory data = abi.encodeCall(
                IGWAssetTracker.setLegacySharedBridgeAddress,
                (bridgehubBurnData.chainId, L1_NULLIFIER.l2BridgeAddress(bridgehubBurnData.chainId))
            );
            address settlementZkChain = BRIDGE_HUB.getZKChain(_settlementChainId);
            IZKChain(settlementZkChain).requestL2ServiceTransaction(GW_ASSET_TRACKER_ADDR, data);
        }

        bytes memory ctmMintData;
        // to avoid stack too deep
        {
            address ctm;
            (zkChain, ctm) = BRIDGE_HUB.forwardedBridgeBurnSetSettlementLayer(
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
            if (_settlementChainId != L1_CHAIN_ID && BRIDGE_HUB.chainTypeManager(_settlementChainId) != ctm) {
                revert SLHasDifferentCTM();
            }
        }
        bytes memory chainMintData = IZKChain(zkChain).forwardedBridgeBurn(
            _settlementChainId == L1_CHAIN_ID
                ? L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS
                : BRIDGE_HUB.getZKChain(_settlementChainId),
            _originalCaller,
            bridgehubBurnData.chainData
        );
        ++migrationNumber[bridgehubBurnData.chainId];

        uint256 batchNumber = IZKChain(zkChain).getTotalBatchesExecuted();
        require(
            MESSAGE_ROOT.chainBatchRoots(bridgehubBurnData.chainId, batchNumber) != bytes32(0),
            ChainBatchRootNotSet(bridgehubBurnData.chainId, batchNumber)
        );
        require(
            MESSAGE_ROOT.chainBatchRoots(bridgehubBurnData.chainId, batchNumber + 1) == bytes32(0),
            NextChainBatchRootAlreadySet(bridgehubBurnData.chainId, batchNumber + 1)
        );
        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgehubBurnData.chainId,
            baseTokenAssetId: BRIDGE_HUB.baseTokenAssetId(bridgehubBurnData.chainId),
            batchNumber: batchNumber,
            ctmData: ctmMintData,
            chainData: chainMintData,
            migrationNumber: migrationNumber[bridgehubBurnData.chainId]
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
        if (currentMigrationNumber != 0) {
            require(
                currentMigrationNumber + 1 == bridgehubMintData.migrationNumber,
                MigrationNumberMismatch(currentMigrationNumber + 1, bridgehubMintData.migrationNumber)
            );
        }
        migrationNumber[bridgehubMintData.chainId] = bridgehubMintData.migrationNumber;

        (address zkChain, address ctm) = BRIDGE_HUB.forwardedBridgeMint(
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
            BRIDGE_HUB.registerNewZKChain(bridgehubMintData.chainId, zkChain, false);
            MESSAGE_ROOT.addNewChain(bridgehubMintData.chainId, bridgehubMintData.batchNumber);
        } else {
            MESSAGE_ROOT.setMigratingChainBatchRoot(bridgehubMintData.chainId, bridgehubMintData.migrationNumber);
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

        (address zkChain, address ctm) = BRIDGE_HUB.forwardedBridgeRecoverFailedTransfer(bridgehubBurnData.chainId);

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
        if (_previousSettlementLayerChainId == 0 && _currentSettlementLayerChainId == L1_CHAIN_ID) {
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
