// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehubBase, BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData} from "./IBridgehubBase.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";

import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "../common/Config.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {IncorrectChainAssetId, IncorrectSender, MigrationNotToL1, MigrationNumberAlreadySet, MigrationNumberMismatch, NotSystemContext, OnlyAssetTrackerOrChain, OnlyChain, SLHasDifferentCTM, ZKChainNotRegistered, IteratedMigrationsNotSupported} from "./L1BridgehubErrors.sol";
import {ChainIdNotRegistered, MigrationPaused, NotAssetRouter, NotL1} from "../common/L1ContractErrors.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

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
                            EXTERNAL GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The asset ID of ETH token
    function ETH_TOKEN_ASSET_ID() external view virtual returns (bytes32);

    /// @notice The chain ID of L1
    function L1_CHAIN_ID() external view virtual returns (uint256);

    /// @notice The bridgehub contract
    function BRIDGEHUB() external view virtual returns (address);

    /// @notice The message root contract
    function MESSAGE_ROOT() external view virtual returns (address);

    /// @notice The asset router contract
    function ASSET_ROUTER() external view virtual returns (address);

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view virtual returns (bytes32);

    function _l1ChainId() internal view virtual returns (uint256);

    function _bridgehub() internal view virtual returns (address);

    function _messageRoot() internal view virtual returns (address);

    function _assetRouter() internal view virtual returns (address);

    function _assetTracker() internal view virtual returns (address);

    /// @notice Used to pause the migrations of chains. Used for upgrades.
    bool public migrationPaused;

    /// @notice Used to track the number of times each chain has migrated.
    /// NOTE: this mapping may be deprecated in the future, don't rely on it!
    mapping(uint256 chainId => uint256 migrationNumber) public migrationNumber;

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

    modifier onlyAssetTrackerOrChain(uint256 _chainId) {
        if (msg.sender != _assetTracker() && msg.sender != IBridgehubBase(_bridgehub()).getZKChain(_chainId)) {
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
                            V30 Upgrade
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
    function setMigrationNumberForV30(uint256 _chainId) external onlyChain(_chainId) {
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

        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgehubBurnData.chainId,
            baseTokenAssetId: IBridgehubBase(_bridgehub()).baseTokenAssetId(bridgehubBurnData.chainId),
            batchNumber: batchNumber,
            ctmData: ctmMintData,
            chainData: chainMintData,
            migrationNumber: migrationNumber[bridgehubBurnData.chainId],
            v30UpgradeChainBatchNumber: IMessageRoot(_messageRoot()).v30UpgradeChainBatchNumber(
                bridgehubBurnData.chainId
            )
        });
        bridgehubMintData = abi.encode(bridgeMintStruct);

        emit MigrationStarted(bridgehubBurnData.chainId, _assetId, _settlementChainId);
    }

    function _setMigrationInProgressOnL1(uint256 _chainId) internal virtual {
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
            // that the `v30UpgradeChainBatchNumber` is not in conflict with the existing values.
            IMessageRoot(_messageRoot()).setMigratingChainBatchRoot(
                bridgehubMintData.chainId,
                bridgehubMintData.batchNumber,
                bridgehubMintData.v30UpgradeChainBatchNumber
            );
        }

        IZKChain(zkChain).forwardedBridgeMint(bridgehubMintData.chainData, contractAlreadyDeployed);

        emit MigrationFinalized(bridgehubMintData.chainId, _assetId, zkChain);
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
