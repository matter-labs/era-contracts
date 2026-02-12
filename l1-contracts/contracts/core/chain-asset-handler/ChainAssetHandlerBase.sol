// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehubBase, BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData} from "../bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {TokenBridgingData} from "../../common/Messaging.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../../bridge/ntv/INativeTokenVaultBase.sol";

import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1, MAX_ALLOWED_NUMBER_OF_MIGRATIONS} from "../../common/Config.sol";
import {IncorrectChainAssetId, IncorrectSender, MigrationNotToL1, MigrationNumberMismatch, NotSystemContext, OnlyChain, SLHasDifferentCTM, ZKChainNotRegistered, IteratedMigrationsNotSupported} from "../bridgehub/L1BridgehubErrors.sol";
import {ChainIdNotRegistered, MigrationPaused, NotAssetRouter} from "../../common/L1ContractErrors.sol";
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
    /// @dev It is assumed that during the release of the v31 upgrade all chains settle on L1,
    /// so they will all start with `migrationNumber` equal to 0. Note, that ZKsync Era that used to settle on ZK Gateway
    /// will also start with migration number equal to 0.
    /// NOTE: this mapping may be deprecated in the future, don't rely on it!
    mapping(uint256 chainId => uint256 migrationNumber) public migrationNumber;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[43] private __gap;

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
        uint256 chainId = bridgehubBurnData.chainId;
        require(
            _assetId == IBridgehubBase(_bridgehub()).ctmAssetIdFromChainId(chainId),
            IncorrectChainAssetId(_assetId, IBridgehubBase(_bridgehub()).ctmAssetIdFromChainId(chainId))
        );
        address zkChain = IBridgehubBase(_bridgehub()).getZKChain(chainId);

        bytes memory ctmMintData;
        // to avoid stack too deep
        {
            address ctm;
            (zkChain, ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeBurnSetSettlementLayer(
                chainId,
                _settlementChainId
            );

            if (zkChain == address(0)) {
                revert ZKChainNotRegistered();
            }
            if (_originalCaller != IZKChain(zkChain).getAdmin()) {
                revert IncorrectSender(_originalCaller, IZKChain(zkChain).getAdmin());
            }

            ctmMintData = IChainTypeManager(ctm).forwardedBridgeBurn(chainId, bridgehubBurnData.ctmData);

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
            _setMigrationInProgressOnL1(chainId);
        }
        // to avoid stack too deep
        bridgehubMintData = _finalizeBridgeBurn({
            _chainId: chainId,
            _settlementChainId: _settlementChainId,
            _assetId: _assetId,
            _zkChain: zkChain,
            _originalCaller: _originalCaller,
            _ctmMintData: ctmMintData,
            _chainData: bridgehubBurnData.chainData
        });
    }

    /// @dev Handles chain burn, migration bookkeeping, and builds the bridgehub mint data.
    /// @dev Extracted from bridgeBurn to avoid stack-too-deep.
    function _finalizeBridgeBurn(
        uint256 _chainId,
        uint256 _settlementChainId,
        bytes32 _assetId,
        address _zkChain,
        address _originalCaller,
        bytes memory _ctmMintData,
        bytes memory _chainData
    ) internal returns (bytes memory) {
        bytes memory chainMintData = IZKChain(_zkChain).forwardedBridgeBurn(
            _settlementChainId == _l1ChainId()
                ? L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS
                : IBridgehubBase(_bridgehub()).getZKChain(_settlementChainId),
            _originalCaller,
            _chainData
        );
        uint256 currentMigrationNum = migrationNumber[_chainId];
        // Iterated migrations are not supported to avoid asset migration number complications related to token balance migration.
        // This means a chain can migrate to GW and back to L1 but only once.
        require(currentMigrationNum < MAX_ALLOWED_NUMBER_OF_MIGRATIONS, IteratedMigrationsNotSupported());
        ++currentMigrationNum;
        migrationNumber[_chainId] = currentMigrationNum;

        uint256 batchNumber = IMessageRoot(_messageRoot()).currentChainBatchNumber(_chainId);

        // Track migration interval for settlement layer validation.
        // When migrating FROM L1 TO a settlement layer, record the last L1 batch number and the SL chain ID.
        if (block.chainid == _l1ChainId()) {
            _recordMigrationToSL(_chainId, _settlementChainId, batchNumber, currentMigrationNum);
        }

        bytes memory bridgehubMintData = _buildBridgehubMintData({
            _chainId: _chainId,
            _batchNumber: batchNumber,
            _ctmMintData: _ctmMintData,
            _chainMintData: chainMintData,
            _currentMigrationNum: currentMigrationNum
        });

        emit MigrationStarted(
            _chainId,
            currentMigrationNum,
            _assetId,
            _settlementChainId
        );

        return bridgehubMintData;
    }

    function _recordMigrationToSL(
        uint256 _chainId,
        uint256 _settlementChainId,
        uint256 _batchNumber,
        uint256 _currentMigrationNum
    ) internal virtual;

    function _recordMigrationFromSL(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _currentMigrationNum
    ) internal virtual;

    function _buildBridgehubMintData(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes memory _ctmMintData,
        bytes memory _chainMintData,
        uint256 _currentMigrationNum
    ) internal view returns (bytes memory) {
        bytes32 assetId = IBridgehubBase(_bridgehub()).baseTokenAssetId(_chainId);
        TokenBridgingData memory baseTokenBridgingData = TokenBridgingData({
            assetId: assetId,
            originToken: address(0),
            originChainId: 0
        });
        if (block.chainid == _l1ChainId()) {
            // We only need to define these values when migrating to GW
            // This is so that the GW Asset Tracker can register the chain's base token
            IL1AssetRouter l1AssetRouter = IL1AssetRouter(address(_assetRouter()));
            INativeTokenVaultBase l1Ntv = l1AssetRouter.nativeTokenVault();
            baseTokenBridgingData.originToken = l1Ntv.originToken(assetId);
            baseTokenBridgingData.originChainId = l1Ntv.originChainId(assetId);
        }

        return
            abi.encode(
                BridgehubMintCTMAssetData({
                    chainId: _chainId,
                    baseTokenBridgingData: baseTokenBridgingData,
                    batchNumber: _batchNumber,
                    ctmData: _ctmMintData,
                    chainData: _chainMintData,
                    migrationNumber: _currentMigrationNum
                })
            );
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
                currentMigrationNumber == MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
                MigrationNumberMismatch(MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, currentMigrationNumber)
            );
            require(
                bridgehubMintData.migrationNumber == MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
                MigrationNumberMismatch(MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1, bridgehubMintData.migrationNumber)
            );
        }
        migrationNumber[bridgehubMintData.chainId] = bridgehubMintData.migrationNumber;
        _recordMigrationFromSL(
            bridgehubMintData.chainId,
            bridgehubMintData.batchNumber,
            bridgehubMintData.migrationNumber
        );

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeMint(
            _assetId,
            bridgehubMintData.chainId,
            bridgehubMintData.baseTokenBridgingData
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

        emit MigrationFinalized(bridgehubMintData.chainId, bridgehubMintData.migrationNumber, _assetId, zkChain);
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
