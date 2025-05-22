// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// import {console} from "forge-std/console.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesInner, L2TransactionRequestTwoBridgesOuter, RouteBridgehubDepositStruct} from "./IBridgehub.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IInteropCenter} from "./IInteropCenter.sol";

import {L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER, TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {BUNDLE_IDENTIFIER, BridgehubL2TransactionRequest, BundleMetadata, GasFields, InteropBundle, InteropCall, InteropCallRequest, InteropCallStarter, InteropTrigger, L2CanonicalTransaction, L2Log, L2Message, TRIGGER_IDENTIFIER, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {BridgehubOnL1, ChainIdNotRegistered, MsgValueMismatch, Unauthorized, WrongMagicValue} from "../common/L1ContractErrors.sol";
import {AlreadyCurrentSL, ChainIdAlreadyPresent, ChainNotLegacy, ChainNotPresentInCTM, DirectCallNonEmptyValue, HyperchainNotRegistered, IncorrectChainAssetId, IncorrectSender, NotAssetRouter, NotCurrentSettlementLayer, NotInGatewayMode, NotL1, NotRelayedSender, SLNotWhitelisted, SecondBridgeAddressTooLow} from "./L1BridgehubErrors.sol";
import {IMailboxImpl} from "../state-transition/chain-interfaces/IMailboxImpl.sol";
import {IAssetTracker} from "../bridge/asset-tracker/IAssetTracker.sol";

import {TransientInterop} from "./TransientInterop.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The InteropCenter contract serves as the primary entry point for L1<->L2 communication,
/// facilitating interactions between end user and bridges.
contract InteropCenter is IInteropCenter, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @notice The bridgehub, responsible for registering chains.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by this shared Bridge.
    address public assetRouter;

    IAssetTracker public assetTracker;

    /// @notice The number of total sent bundles, used for bundle id generation and uniqueness.
    uint256 public bundleCount;

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

    modifier onlyL2() {
        if (L1_CHAIN_ID == block.chainid) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2NotToL1(uint256 _destinationChainId) {
        if (_destinationChainId == L1_CHAIN_ID) {
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
    /// the order of deployment is InteropCenter, other contracts, and then we call this.
    /// @param _assetRouter the shared bridge address
    function setAddresses(address _assetRouter, address _assetTracker) external onlyOwner {
        assetRouter = _assetRouter;
        assetTracker = IAssetTracker(_assetTracker);
    }
    /*//////////////////////////////////////////////////////////////
                        Message interface
    //////////////////////////////////////////////////////////////*/

    function sendMessage(bytes calldata _msg) external onlyL2 returns (bytes32 canonicalTxHash) {
        // kl todo modify messenger to specify original msg.sender
        return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(_msg);
    }

    /*//////////////////////////////////////////////////////////////
                        Bundle interface
    //////////////////////////////////////////////////////////////*/

    function startBundle(
        uint256 _destinationChainId
    ) external override onlyL2NotToL1(_destinationChainId) returns (bytes32 bundleId) {
        bundleId = _startBundle(_destinationChainId, msg.sender);
    }

    function _startBundle(uint256 _destinationChainId, address _sender) public returns (bytes32 bundleId) {
        bundleId = keccak256(abi.encodePacked(bundleCount, _sender, _destinationChainId));
        bundleCount++;
        TransientInterop.setBundleMetadata(
            bundleId,
            BundleMetadata({destinationChainId: _destinationChainId, sender: _sender, callCount: 0, totalValue: 0})
        );
    }

    function addCallToBundle(
        bytes32 _bundleId,
        InteropCallRequest memory _interopCallRequest
    ) external override onlyL2 {
        _addCallToBundle(_bundleId, _interopCallRequest, msg.sender);
    }

    function _addCallToBundle(
        bytes32 _bundleId,
        InteropCallRequest memory _interopCallRequest,
        address _sender
    ) internal {
        InteropCall memory interopCall;
        interopCall.to = _interopCallRequest.to;
        interopCall.data = _interopCallRequest.data;
        interopCall.value = _interopCallRequest.value;
        interopCall.from = _sender;
        TransientInterop.addCallToBundle(_bundleId, interopCall);
    }

    function finishAndSendBundle(
        bytes32 _bundleId,
        address _executionAddress
    ) external payable override returns (bytes32 interopBundleHash) {
        interopBundleHash = _finishAndSendBundle(_bundleId, _executionAddress);
    }

    function _finishAndSendBundle(
        bytes32 _bundleId,
        address _executionAddress
    ) internal returns (bytes32 interopBundleHash) {
        require(block.chainid != L1_CHAIN_ID, "InteropCenter: Cannot send bundle from L1");
        interopBundleHash = _finishAndSendBundleLong(_bundleId, _executionAddress, msg.value, msg.sender);
    }

    function _finishAndSendBundleLong(
        bytes32 _bundleId,
        address _executionAddress,
        uint256 _receivedMsgValue,
        address _sender
    ) internal returns (bytes32 interopBundleHash) {
        BundleMetadata memory bundleMetadata = TransientInterop.getBundleMetadata(_bundleId);
        if (bundleMetadata.sender != _sender) {
            revert Unauthorized(_sender);
        }

        InteropCall[] memory interopCalls = new InteropCall[](bundleMetadata.callCount);
        for (uint256 i = 0; i < bundleMetadata.callCount; i++) {
            InteropCall memory interopCall = TransientInterop.getBundleCall(_bundleId, i);
            interopCalls[i] = interopCall;
        }

        _ensureCorrectTotalValue(
            bundleMetadata.destinationChainId,
            bundleMetadata.sender,
            bundleMetadata.totalValue,
            _receivedMsgValue
        );

        address[] memory executionAddresses = new address[](1);
        InteropBundle memory interopBundle = InteropBundle({
            destinationChainId: bundleMetadata.destinationChainId,
            calls: interopCalls,
            executionAddress: _executionAddress
        });
        bytes memory interopBundleBytes = abi.encode(interopBundle);
        interopBundleHash = keccak256(interopBundleBytes);
        if (block.chainid == L1_CHAIN_ID) {
            // we construct the L2CanonicalTransaction manually
            // when sending the trigger
            return interopBundleHash;
        } else {
            // TODO use canonicalTxHash for linking it to the trigger, instead of interopBundleHash
            bytes32 canonicalTxHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
                bytes.concat(BUNDLE_IDENTIFIER, interopBundleBytes)
            );
            emit InteropBundleSent(canonicalTxHash, interopBundleHash, interopBundle);
        }
    }

    function _ensureCorrectTotalValue(
        uint256 _destinationChainId,
        address _initiator,
        uint256 _totalValue,
        uint256 _receivedMsgValue
    ) internal {
        if (_totalValue == 0) {
            return;
        }

        bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
        uint256 baseTokenMsgValue;
        if (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) {
            // kl todo until we sort out chain registration on L2s we assume the same base token.
            if (_receivedMsgValue != _totalValue) {
                revert MsgValueMismatch(_totalValue, _receivedMsgValue);
            }
            baseTokenMsgValue = _totalValue;
        } else {
            if (_receivedMsgValue != 0) {
                revert MsgValueMismatch(0, _receivedMsgValue);
            }
            baseTokenMsgValue = 0;
        }

        // slither-disable-next-line arbitrary-send-eth
        if (block.chainid == L1_CHAIN_ID) {
            IL1AssetRouter(assetRouter).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _destinationChainId,
                tokenAssetId,
                _initiator,
                _totalValue
            );
        } else {
            L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue{value: _totalValue}();
        }
    }


    /*//////////////////////////////////////////////////////////////
                        EOA helpers
    //////////////////////////////////////////////////////////////*/

    function sendCall(
        uint256 _destinationChainId,
        address _destinationAddress,
        bytes calldata _data,
        uint256 _value
    ) public payable onlyL2NotToL1(_destinationChainId) returns (bytes32) {
        bytes32 bundleId = _startBundle(_destinationChainId, msg.sender);
        _addCallToBundle(
            bundleId,
            InteropCallRequest({to: _destinationAddress, value: _value, data: _data}),
            msg.sender
        );
        bytes32 bundleHash = _finishAndSendBundleLong(bundleId, address(0), msg.value, msg.sender);
        return bundleHash;
    }

    struct ExtraInputs {
        address sender;
        address executionAddress;
        address refundRecipient;
        bytes[] factoryDeps;
    }


    struct ViaIRStruct {
        bytes32 feeBundleId;
        bytes32 feeBundleHash;
        bytes32 executionBundleId;
        bytes32 executionBundleHash;
    }


    function _requestFromStarter(InteropCallStarter memory callStarter) internal returns (InteropCallRequest memory) {
        if (callStarter.value != 0) {
            revert DirectCallNonEmptyValue(callStarter.nextContract);
        }
        return
            InteropCallRequest({
                to: callStarter.nextContract,
                data: callStarter.data,
                value: callStarter.requestedInteropCallValue
            });
    }


    function addCallToBundleFromRequest(
        bytes32 _bundleId,
        uint256 _value,
        L2TransactionRequestTwoBridgesInner memory _request
    ) public onlyL2 {
        // console.log("addCallToBundleFromRequest", msg.sender);
        _addCallToBundle(
            _bundleId,
            InteropCallRequest({to: _request.l2Contract, value: _value, data: _request.l2Calldata}),
            msg.sender
        );
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
        return _requestL2TransactionDirect(msg.sender, _request);
        // return _requestInteropSingleDirectCall(_request, msg.sender);
    }

    function requestL2TransactionDirectSender(
        address _sender,
        L2TransactionRequestDirect calldata _request
    ) external payable override onlyBridgehub returns (bytes32 canonicalTxHash) {
        return _requestL2TransactionDirect(_sender, _request);
        // return _requestInteropSingleDirectCall(_request, _sender);
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
            if (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) {
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
            }),
            _sender
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
        // note this is a temporary hack so that I don't have to migrate all the tooling to the new interface
        // note claimFailedDeposit does not work with this hack!
        return _requestL2TransactionTwoBridges(msg.sender, false, _request);
        // return _requestInteropSingleCall(_request, msg.sender);
    }

    function requestL2TransactionTwoBridgesSender(
        address _sender,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override onlyBridgehub returns (bytes32 canonicalTxHash) {
        // note this is a temporary hack so that I don't have to migrate all the tooling to the new interface
        // note claimFailedDeposit does not work with this hack!
        return _requestL2TransactionTwoBridges(_sender, true, _request);
        // return _requestInteropSingleCall(_request, _sender);
    }

    function _requestL2TransactionTwoBridges(
        address _sender,
        bool _routeViaBridgehub,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) internal nonReentrant whenNotPaused onlyL1 returns (bytes32 canonicalTxHash) {
        if (_request.secondBridgeAddress <= BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS) {
            revert SecondBridgeAddressTooLow(_request.secondBridgeAddress, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS);
        }

        {
            bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_request.chainId);
            uint256 baseTokenMsgValue;
            if (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) {
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
        L2TransactionRequestTwoBridgesInner memory outputRequest;
        if (_request.secondBridgeAddress == address(assetRouter) || !_routeViaBridgehub) {
            // slither-disable-next-line arbitrary-send-eth
            outputRequest = IL1AssetRouter(_request.secondBridgeAddress).bridgehubDeposit{
                value: _request.secondBridgeValue
            }(_request.chainId, _sender, _request.l2Value, _request.secondBridgeCalldata);
        } else {
            outputRequest = BRIDGE_HUB.routeBridgehubDeposit{value: _request.secondBridgeValue}(
                RouteBridgehubDepositStruct({
                    secondBridgeAddress: _request.secondBridgeAddress,
                    chainId: _request.chainId,
                    sender: _sender,
                    l2Value: _request.l2Value,
                    secondBridgeCalldata: _request.secondBridgeCalldata
                })
            );
        }

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
            }),
            _sender
        );

        if (_request.secondBridgeAddress == address(assetRouter)) {
            IAssetRouterBase(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
                _request.chainId,
                outputRequest.txDataHash,
                canonicalTxHash
            );
        } else {
            BRIDGE_HUB.routeBridgehubConfirmL2Transaction(
                _request.secondBridgeAddress,
                _request.chainId,
                outputRequest.txDataHash,
                canonicalTxHash
            );
        }
    }

    /// @notice This function is used to send a request to the ZK chain.
    /// @param _chainId the chainId of the chain
    /// @param _refundRecipient the refund recipient
    /// @param _request the request
    /// @return canonicalTxHash the canonical transaction hash
    function _sendRequest(
        uint256 _chainId,
        address _refundRecipient,
        BridgehubL2TransactionRequest memory _request,
        address _sender
    ) internal returns (bytes32 canonicalTxHash) {
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _sender);
        _request.refundRecipient = refundRecipient;
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        if (zkChain != address(0)) {
            canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(_request);
        } else {
            revert ChainIdNotRegistered(_chainId);
        }
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
                            GW function
    //////////////////////////////////////////////////////////////*/

    /// @notice Used to forward a transaction on the gateway to the chains mailbox (from L1).
    /// @param _chainId the chainId of the chain
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp for the transaction
    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        uint256 _baseTokenAmount,
        bytes32 _assetId,
        uint256 _amount
    ) external override onlySettlementLayerRelayedSender {
        if (L1_CHAIN_ID == block.chainid) {
            revert NotInGatewayMode();
        }
        if (_baseTokenAmount > 0) {
            IAssetTracker(L2_ASSET_TRACKER_ADDR).handleChainBalanceIncrease(
                _chainId,
                BRIDGE_HUB.baseTokenAssetId(_chainId),
                _baseTokenAmount,
                false
            );
        }
        if (_amount > 0) {
            IAssetTracker(L2_ASSET_TRACKER_ADDR).handleChainBalanceIncrease(_chainId, _assetId, _amount, false);
        }
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        IZKChain(zkChain).bridgehubRequestL2TransactionOnGateway(_canonicalTxHash, _expirationTimestamp);
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
