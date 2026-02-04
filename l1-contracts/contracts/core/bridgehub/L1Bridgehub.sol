// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {ETH_TOKEN_ADDRESS, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";
import {BridgehubBase} from "./BridgehubBase.sol";
import {IL1Bridgehub} from "./IL1Bridgehub.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner} from "./IBridgehubBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IAssetRouterShared} from "../../bridge/asset-router/IAssetRouterShared.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {ICTMDeploymentTracker} from "../ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {SecondBridgeAddressTooLow} from "./L1BridgehubErrors.sol";
import {SettlementLayersMustSettleOnL1} from "../../common/L1ContractErrors.sol";
import {ChainIdAlreadyExists, ChainIdMismatch, IncorrectBridgeHubAddress, MsgValueMismatch, WrongMagicValue, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {IL1CrossChainSender} from "../../bridge/interfaces/IL1CrossChainSender.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
contract L1Bridgehub is BridgehubBase, IL1Bridgehub {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @dev Chain ID of L1.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is a temporary security measure.
    uint256 public immutable MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice to avoid parity hack
    constructor(address _owner, uint256 _maxNumberOfZKChains) reentrancyGuardInitializer {
        L1_CHAIN_ID = block.chainid;
        _disableInitializers();
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones on L1Bridgehub.
        // We will change this with interop.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @dev Returns the asset ID of ETH token for internal use.
    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    /// @dev Returns the maximum number of ZK chains for internal use.
    function _maxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }

    /// @dev Returns the L1 chain ID for internal use.
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    /// @notice Used to register a chain as a settlement layer.
    /// @param _newSettlementLayerChainId the chainId of the chain
    /// @param _isWhitelisted whether the chain is a whitelisted settlement layer
    function registerSettlementLayer(uint256 _newSettlementLayerChainId, bool _isWhitelisted) external onlyOwner {
        if (settlementLayer[_newSettlementLayerChainId] != block.chainid) {
            revert SettlementLayersMustSettleOnL1();
        }
        whitelistedSettlementLayers[_newSettlementLayerChainId] = _isWhitelisted;
        emit SettlementLayerRegistered(_newSettlementLayerChainId, _isWhitelisted);
    }

    /// @notice Register new chain. New chains can be only registered on Bridgehub deployed on L1. Later they can be moved to any other layer.
    /// @notice for Eth the baseToken address is 1
    /// @param _chainId the chainId of the chain
    /// @param _chainTypeManager the state transition manager address
    /// @param _baseTokenAssetId the base token asset id of the chain
    /// @param _salt the salt for the chainId, currently not used
    /// @param _admin the admin of the chain
    /// @param _initData the fixed initialization data for the chain
    /// @param _factoryDeps the factory dependencies for the chain's deployment
    function createNewChain(
        uint256 _chainId,
        address _chainTypeManager,
        bytes32 _baseTokenAssetId,
        // solhint-disable-next-line no-unused-vars
        uint256 _salt,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external onlyOwnerOrAdmin nonReentrant whenNotPaused returns (uint256) {
        _validateChainParams({_chainId: _chainId, _assetId: _baseTokenAssetId, _chainTypeManager: _chainTypeManager});

        chainTypeManager[_chainId] = _chainTypeManager;

        baseTokenAssetId[_chainId] = _baseTokenAssetId;
        settlementLayer[_chainId] = block.chainid;

        address chainAddress = IChainTypeManager(_chainTypeManager).createNewChain({
            _chainId: _chainId,
            _baseTokenAssetId: _baseTokenAssetId,
            _admin: _admin,
            _initData: _initData,
            _factoryDeps: _factoryDeps
        });
        _registerNewZKChain(_chainId, chainAddress, true);
        messageRoot.addNewChain(_chainId, 0);

        emit NewChain(_chainId, _chainTypeManager, _admin);
        return _chainId;
    }

    /// @notice The mailbox is called directly after the assetRouter received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the nativeTokenVault.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token.
    /// In case allowance is provided to the Asset Router, then it will be transferred to NTV.
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable override nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        // Note: If the ZK chain with corresponding `chainId` is not yet created,
        // the transaction will revert on `bridgehubRequestL2Transaction` as call to zero address.
        {
            bytes32 tokenAssetId = baseTokenAssetId[_request.chainId];
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                if (msg.value != _request.mintValue) {
                    revert MsgValueMismatch(_request.mintValue, msg.value);
                }
            } else {
                if (msg.value != 0) {
                    revert MsgValueMismatch(0, msg.value);
                }
            }

            // slither-disable-next-line arbitrary-send-eth
            IAssetRouterShared(address(assetRouter)).bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                tokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }

        canonicalTxHash = _sendRequest(
            _request.chainId,
            _request.refundRecipient,
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _request.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: _request.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: address(0)
            })
        );
    }

    /// @notice After depositing funds to the assetRouter, the secondBridge is called
    ///  to return the actual L2 message which is sent to the Mailbox.
    ///  This assumes that either ether is the base token or
    ///  the msg.sender has approved the nativeTokenVault with the mintValue,
    ///  and also the necessary approvals are given for the second bridge.
    ///  In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    /// @notice The logic of this bridge is to allow easy depositing for bridges.
    /// Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
    /// the user to approve for each token only its respective bridge
    /// @notice This function is great for contract calls to L2, the secondBridge can be any contract.
    /// @param _request the request for the L2 transaction
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        if (_request.secondBridgeAddress <= BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS) {
            revert SecondBridgeAddressTooLow(_request.secondBridgeAddress, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS);
        }

        {
            bytes32 tokenAssetId = baseTokenAssetId[_request.chainId];
            uint256 baseTokenMsgValue;
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                if (msg.value != _request.mintValue + _request.secondBridgeValue) {
                    revert MsgValueMismatch(_request.mintValue + _request.secondBridgeValue, msg.value);
                }
                baseTokenMsgValue = _request.mintValue;
            } else {
                if (msg.value != _request.secondBridgeValue) {
                    revert MsgValueMismatch(_request.secondBridgeValue, msg.value);
                }
                baseTokenMsgValue = 0;
            }

            // slither-disable-next-line arbitrary-send-eth
            IAssetRouterShared(address(assetRouter)).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _request.chainId,
                tokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }

        // slither-disable-next-line arbitrary-send-eth
        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1CrossChainSender(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            msg.sender,
            _request.l2Value,
            _request.secondBridgeCalldata
        );

        if (outputRequest.magicValue != TWO_BRIDGES_MAGIC_VALUE) {
            revert WrongMagicValue(uint256(TWO_BRIDGES_MAGIC_VALUE), uint256(outputRequest.magicValue));
        }

        canonicalTxHash = _sendRequest(
            _request.chainId,
            _request.refundRecipient,
            BridgehubL2TransactionRequest({
                sender: _request.secondBridgeAddress,
                contractL2: outputRequest.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: outputRequest.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: outputRequest.factoryDeps,
                refundRecipient: address(0)
            })
        );

        IL1AssetRouter(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
            _request.chainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }

    /// @notice Sets contract addresses
    function setAddresses(
        address _assetRouter,
        ICTMDeploymentTracker _l1CtmDeployer,
        IMessageRoot _messageRoot,
        address _chainAssetHandler,
        address _chainRegistrationSender
    ) external override onlyOwnerOrUpgrader {
        assetRouter = IAssetRouterBase(_assetRouter);
        l1CtmDeployer = _l1CtmDeployer;
        messageRoot = _messageRoot;
        chainAssetHandler = _chainAssetHandler;
        chainRegistrationSender = _chainRegistrationSender;
    }

    /// @dev Registers an already deployed chain with the bridgehub
    /// @param _chainId The chain Id of the chain
    /// @param _zkChain Address of the zkChain
    function registerAlreadyDeployedZKChain(uint256 _chainId, address _zkChain) external onlyOwner {
        if (_zkChain == address(0)) {
            revert ZeroAddress();
        }
        // slither-disable-next-line unused-return
        (bool exists, ) = zkChainMap.tryGet(_chainId);
        if (exists) {
            revert ChainIdAlreadyExists();
        }
        if (IZKChain(_zkChain).getChainId() != _chainId) {
            revert ChainIdMismatch();
        }

        address ctm = IZKChain(_zkChain).getChainTypeManager();
        address chainAdmin = IZKChain(_zkChain).getAdmin();
        bytes32 chainBaseTokenAssetId = IZKChain(_zkChain).getBaseTokenAssetId();
        address bridgeHub = IZKChain(_zkChain).getBridgehub();
        uint256 batchNumber = IZKChain(_zkChain).getTotalBatchesExecuted();

        if (bridgeHub != address(this)) {
            revert IncorrectBridgeHubAddress(bridgeHub);
        }

        _validateChainParams({_chainId: _chainId, _assetId: chainBaseTokenAssetId, _chainTypeManager: ctm});

        chainTypeManager[_chainId] = ctm;

        baseTokenAssetId[_chainId] = chainBaseTokenAssetId;
        settlementLayer[_chainId] = block.chainid;

        _registerNewZKChain(_chainId, _zkChain, true);
        messageRoot.addNewChain(_chainId, batchNumber);

        emit NewChain(_chainId, ctm, chainAdmin);
    }
}
