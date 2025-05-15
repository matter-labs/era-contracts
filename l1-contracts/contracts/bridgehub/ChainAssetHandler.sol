// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner, BridgehubMintCTMAssetData, BridgehubBurnCTMAssetData} from "./IBridgehub.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IL1BaseTokenAssetHandler} from "../bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";

import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER, L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ICTMDeploymentTracker} from "./ICTMDeploymentTracker.sol";
import {NotL1, NotRelayedSender, NotAssetRouter, ChainIdAlreadyPresent, ChainNotPresentInCTM, SecondBridgeAddressTooLow, NotInGatewayMode, SLNotWhitelisted, IncorrectChainAssetId, NotCurrentSL, HyperchainNotRegistered, IncorrectSender, AlreadyCurrentSL, ChainNotLegacy} from "./L1BridgehubErrors.sol";
import {NoCTMForAssetId, SettlementLayersMustSettleOnL1, MigrationPaused, AssetIdAlreadyRegistered, ChainIdNotRegistered, AssetHandlerNotRegistered, ZKChainLimitReached, CTMAlreadyRegistered, CTMNotRegistered, ZeroChainId, ChainIdTooBig, BridgeHubAlreadyRegistered, MsgValueMismatch, ZeroAddress, Unauthorized, SharedBridgeNotSet, WrongMagicValue, ChainIdAlreadyExists, ChainIdMismatch, ChainIdCantBeCurrentChain, EmptyAssetId, AssetIdNotSupported, IncorrectBridgeHubAddress} from "../common/L1ContractErrors.sol";

import {AssetHandlerModifiers} from "../bridge/interfaces/AssetHandlerModifiers.sol";
import {IChainAssetHandler} from "./IChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// Bridgehub is also an IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
contract ChainAssetHandler is
    IChainAssetHandler,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AssetHandlerModifiers
{
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    uint256 internal immutable L1_CHAIN_ID;

    IBridgehub internal immutable BRIDGEHUB;

    IMessageRoot internal immutable MESSAGE_ROOT;

    address internal immutable ASSET_ROUTER;

    /// @notice used to pause the migrations of chains. Used for upgrades.
    bool public migrationPaused;

    modifier onlyAssetRouter() {
        if (msg.sender != ASSET_ROUTER) {
            revert NotAssetRouter(msg.sender, ASSET_ROUTER);
        }
        _;
    }

    modifier whenMigrationsNotPaused() {
        if (migrationPaused) {
            revert MigrationPaused();
        }
        _;
    }

    modifier onlyL1() {
        if (L1_CHAIN_ID != block.chainid) {
            revert NotL1(L1_CHAIN_ID, block.chainid);
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
        if (_assetId != BRIDGEHUB.ctmAssetIdFromChainId(bridgehubBurnData.chainId)) {
            revert IncorrectChainAssetId(_assetId, BRIDGEHUB.ctmAssetIdFromChainId(bridgehubBurnData.chainId));
        }

        address zkChain;
        bytes memory ctmMintData;
        // to avoid stack too deep
        {
            address ctm;
            (zkChain, ctm) = BRIDGEHUB.forwardedBridgeBurnSetSettlmentLayer(
                bridgehubBurnData.chainId,
                _settlementChainId
            );

            if (zkChain == address(0)) {
                revert HyperchainNotRegistered();
            }
            if (_originalCaller != IZKChain(zkChain).getAdmin()) {
                revert IncorrectSender(_originalCaller, IZKChain(zkChain).getAdmin());
            }

            ctmMintData = IChainTypeManager(ctm).forwardedBridgeBurn(
                bridgehubBurnData.chainId,
                bridgehubBurnData.ctmData
            );
        }
        bytes memory chainMintData = IZKChain(zkChain).forwardedBridgeBurn(
            _settlementChainId == L1_CHAIN_ID
                ? L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS
                : BRIDGEHUB.getZKChain(_settlementChainId),
            _originalCaller,
            bridgehubBurnData.chainData
        );
        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgehubBurnData.chainId,
            baseTokenAssetId: BRIDGEHUB.baseTokenAssetId(bridgehubBurnData.chainId),
            ctmData: ctmMintData,
            chainData: chainMintData
        });
        bridgehubMintData = abi.encode(bridgeMintStruct);

        emit MigrationStarted(bridgehubBurnData.chainId, _assetId, _settlementChainId);
    }

    /// @dev IL1AssetHandler interface, used to receive a chain on the settlement layer.
    /// @param _assetId the assetId of the chain's CTM
    /// @param _bridgehubMintData the data for the mint
    function bridgeMint(
        uint256, // originChainId
        bytes32 _assetId,
        bytes calldata _bridgehubMintData
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenMigrationsNotPaused {
        BridgehubMintCTMAssetData memory bridgehubMintData = abi.decode(
            _bridgehubMintData,
            (BridgehubMintCTMAssetData)
        );

        (address zkChain, address ctm) = BRIDGEHUB.forwardedBridgeMint(
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
            BRIDGEHUB.registerNewZKChain(bridgehubMintData.chainId, zkChain, false);
            MESSAGE_ROOT.addNewChain(bridgehubMintData.chainId);
        }

        IZKChain(zkChain).forwardedBridgeMint(bridgehubMintData.chainData, contractAlreadyDeployed);

        emit MigrationFinalized(bridgehubMintData.chainId, _assetId, zkChain);
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    // / @param _chainId the chainId of the chain
    /// @param _assetId the assetId of the chain's CTM
    /// @param _data the data for the recovery.
    function bridgeRecoverFailedTransfer(
        uint256,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter onlyL1 {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));

        (address zkChain, address ctm) = BRIDGEHUB.forwardedBridgeRecoverFailedTransfer(bridgehubBurnData.chainId);

        IChainTypeManager(ctm).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        IZKChain(zkChain).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _originalCaller: _depositSender,
            _chainData: bridgehubBurnData.chainData
        });
    }
}
