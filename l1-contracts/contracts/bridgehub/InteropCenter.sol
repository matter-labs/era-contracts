// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

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
import {IInteropCenter} from "./IInteropCenter.sol";

import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER, L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ICTMDeploymentTracker} from "./ICTMDeploymentTracker.sol";
import {MigrationPaused, AssetIdAlreadyRegistered, ChainAlreadyLive, ChainNotLegacy, CTMNotRegistered, ChainIdNotRegistered, AssetHandlerNotRegistered, ZKChainLimitReached, CTMAlreadyRegistered, CTMNotRegistered, ZeroChainId, ChainIdTooBig, BridgeHubAlreadyRegistered, AddressTooLow, MsgValueMismatch, ZeroAddress, Unauthorized, SharedBridgeNotSet, WrongMagicValue, ChainIdAlreadyExists, ChainIdMismatch, ChainIdCantBeCurrentChain, EmptyAssetId, AssetIdNotSupported, IncorrectBridgeHubAddress} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The InteropCenter contract serves as the primary entry point for L1<->L2 communication,
/// facilitating interactions between end user and bridges.
contract InteropCenter is IInteropCenter, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @notice The bridgehub, responsible for registering chains.
    IBridgehub public immutable BRIDGE_HUB;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by this shared Bridge.
    address public assetRouter;

    /// @notice The contract that stores the cross-chain message root for each chain and the aggregated root.
    /// @dev Note that the message root does not contain messages from the chain it is deployed on. It may
    /// be added later on if needed.
    // IMessageRoot public messageRoot;  
    
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAssetRouter() {
        if (msg.sender != assetRouter) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL1() {
        if (L1_CHAIN_ID != block.chainid) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlySettlementLayerRelayedSender() {
        /// There is no sender for the wrapping, we use a virtual address.
        if (msg.sender != SETTLEMENT_LAYER_RELAY_SENDER) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice to avoid parity hack
    constructor(IBridgehub _bridgehub, uint256 _l1ChainId, address _owner) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

        _transferOwnership(_owner);
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer onlyL1 {
        _transferOwnership(_owner);
    }

    /// @notice To set the addresses of some of the ecosystem contracts, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, other contracts, and then we call this.
    /// @param _assetRouter the shared bridge address
    // / @param _l1CtmDeployer the ctm deployment tracker address. Note, that the address of the L1 CTM deployer is provided.
    // / @param _messageRoot the message root address
    function setAddresses(
        address _assetRouter
        // ICTMDeploymentTracker _l1CtmDeployer,
        // IMessageRoot _messageRoot
    ) external onlyOwner {
        assetRouter = _assetRouter;
        // l1CtmDeployer = _l1CtmDeployer;
        // messageRoot = _messageRoot;
    }
       /*//////////////////////////////////////////////////////////////
                        Mailbox forwarder
    //////////////////////////////////////////////////////////////*/

    /// @notice the mailbox is called directly after the assetRouter received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the nativeTokenVault.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token.
    /// In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable override returns (bytes32 canonicalTxHash) {
        _requestL2TransactionDirect(msg.sender, _request);
    }

    function requestL2TransactionDirectSender(
        address _sender, 
        L2TransactionRequestDirect calldata _request
    ) external payable override onlyBridgehub returns (bytes32 canonicalTxHash) {
        _requestL2TransactionDirect(_sender, _request);
    }

    /// @notice the mailbox is called directly after the assetRouter received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the nativeTokenVault.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token.
    /// In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    function _requestL2TransactionDirect(
        address _sender,
        L2TransactionRequestDirect calldata _request
    ) internal nonReentrant whenNotPaused onlyL1 returns (bytes32 canonicalTxHash) {
        // Note: If the ZK chain with corresponding `chainId` is not yet created,
        // the transaction will revert on `bridgehubRequestL2Transaction` as call to zero address.
        {
            bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_request.chainId);
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
            IL1AssetRouter(assetRouter).bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                tokenAssetId,
                _sender,
                _request.mintValue
            );
        }

        canonicalTxHash = _sendRequest(
            _request.chainId,
            _request.refundRecipient,
            BridgehubL2TransactionRequest({
                sender: _sender,
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
    ) external payable override returns (bytes32 canonicalTxHash) {
        _requestL2TransactionTwoBridges(msg.sender, _request);
    }
    
    function requestL2TransactionTwoBridgesSender(
        address _sender,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override onlyBridgehub returns (bytes32 canonicalTxHash) {
        _requestL2TransactionTwoBridges(_sender, _request);
    }

    function _requestL2TransactionTwoBridges(
        address _sender,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) internal nonReentrant whenNotPaused onlyL1 returns (bytes32 canonicalTxHash) {
        if (_request.secondBridgeAddress <= BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS) {
            revert AddressTooLow(_request.secondBridgeAddress);
        }

        {
            bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_request.chainId);
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
            IL1AssetRouter(assetRouter).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _request.chainId,
                tokenAssetId,
                _sender,
                _request.mintValue
            );
        }

        // slither-disable-next-line arbitrary-send-eth
        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1AssetRouter(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            _sender,
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

    /// @notice This function is used to send a request to the ZK chain.
    /// @param _chainId the chainId of the chain
    /// @param _refundRecipient the refund recipient
    /// @param _request the request
    /// @return canonicalTxHash the canonical transaction hash
    function _sendRequest(
        uint256 _chainId,
        address _refundRecipient,
        BridgehubL2TransactionRequest memory _request
    ) internal returns (bytes32 canonicalTxHash) {
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, msg.sender);
        _request.refundRecipient = refundRecipient;
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);

        canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(_request);
    }

    /// @notice Used to forward a transaction on the gateway to the chains mailbox (from L1).
    /// @param _chainId the chainId of the chain
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp for the transaction
    function forwardTransactionOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlySettlementLayerRelayedSender {
        require(L1_CHAIN_ID != block.chainid, "BH: not in sync layer mode");
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        IZKChain(zkChain).bridgehubRequestL2TransactionOnGateway(_canonicalTxHash, _expirationTimestamp);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the ZK chain where to prove L2 message inclusion.
    /// @param _batchNumber The executed L2 batch number in which the message appeared
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message
    /// @return Whether the proof is valid
    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        return IZKChain(zkChain).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the ZK chain where to prove L2 log inclusion.
    /// @param _batchNumber The executed L2 batch number in which the log appeared
    /// @param _index The position of the l2log in the L2 logs Merkle tree
    /// @param _log Information about the sent log
    /// @param _proof Merkle proof for inclusion of the L2 log
    /// @return Whether the proof is correct and L2 log is included in batch
    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        return IZKChain(zkChain).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the ZK chain where to prove L1->L2 tx status.
    /// @param _l2TxHash The L2 canonical transaction hash
    /// @param _l2BatchNumber The L2 batch number where the transaction was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction
    /// @param _status The execution status of the L1 -> L2 transaction (true - success & 0 - fail)
    /// @return Whether the proof is correct and the transaction was actually executed with provided status
    /// NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status!
    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        return
            IZKChain(zkChain).proveL1ToL2TransactionStatus({
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: _status
            });
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        return IZKChain(zkChain).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}