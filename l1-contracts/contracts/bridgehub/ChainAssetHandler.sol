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
contract ChainAssetHandler is IChainAssetHandler, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable, AssetHandlerModifiers {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    modifier onlyAssetRouter() {
        if (msg.sender != assetRouter) {
            revert NotAssetRouter(msg.sender, assetRouter);
        }
        _;
    }

    modifier whenMigrationsNotPaused() {
        if (migrationPaused) {
            revert MigrationPaused();
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
        if (_assetId != ctmAssetIdFromChainId(bridgehubBurnData.chainId)) {
            revert IncorrectChainAssetId(_assetId, ctmAssetIdFromChainId(bridgehubBurnData.chainId));
        }
        
        (address zkChain, address ctm) = BRIDGEHUB.forwardedBridgeBurnSetSettlmentLayer(bridgehubBurnData.chainId, _settlementChainId);

        if (zkChain == address(0)) {
            revert HyperchainNotRegistered();
        }
        if (_originalCaller != IZKChain(zkChain).getAdmin()) {
            revert IncorrectSender(_originalCaller, IZKChain(zkChain).getAdmin());
        }

        bytes memory ctmMintData = IChainTypeManager(ctm).forwardedBridgeBurn(
            bridgehubBurnData.chainId,
            bridgehubBurnData.ctmData
        );
        bytes memory chainMintData = IZKChain(zkChain).forwardedBridgeBurn(
            _settlementChainId == L1_CHAIN_ID
                ? L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS
                : zkChainMap.get(_settlementChainId),
            _originalCaller,
            bridgehubBurnData.chainData
        );
        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgehubBurnData.chainId,
            baseTokenAssetId: baseTokenAssetId[bridgehubBurnData.chainId],
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

        address ctm = ctmAssetIdToAddress[_assetId];
        if (ctm == address(0)) {
            revert NoCTMForAssetId(_assetId);
        }
        if (settlementLayer[bridgehubMintData.chainId] == block.chainid) {
            revert AlreadyCurrentSL(block.chainid);
        }

        settlementLayer[bridgehubMintData.chainId] = block.chainid;
        chainTypeManager[bridgehubMintData.chainId] = ctm;
        baseTokenAssetId[bridgehubMintData.chainId] = bridgehubMintData.baseTokenAssetId;
        // To keep `assetIdIsRegistered` consistent, we'll also automatically register the base token.
        // It is assumed that if the bridging happened, the token was approved on L1 already.
        assetIdIsRegistered[bridgehubMintData.baseTokenAssetId] = true;

        address zkChain = getZKChain(bridgehubMintData.chainId);
        bool contractAlreadyDeployed = zkChain != address(0);
        if (!contractAlreadyDeployed) {
            zkChain = IChainTypeManager(ctm).forwardedBridgeMint(bridgehubMintData.chainId, bridgehubMintData.ctmData);
            if (zkChain == address(0)) {
                revert ChainIdNotRegistered(bridgehubMintData.chainId);
            }
            // We want to allow any chain to be migrated,
            _registerNewZKChain(bridgehubMintData.chainId, zkChain, false);
            messageRoot.addNewChain(bridgehubMintData.chainId);
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

        settlementLayer[bridgehubBurnData.chainId] = block.chainid;

        IChainTypeManager(chainTypeManager[bridgehubBurnData.chainId]).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        IZKChain(getZKChain(bridgehubBurnData.chainId)).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _originalCaller: _depositSender,
            _chainData: bridgehubBurnData.chainData
        });
    }

    
}