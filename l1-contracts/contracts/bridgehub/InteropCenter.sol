// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// import {console} from "forge-std/console.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner, RouteBridgehubDepositStruct} from "./IBridgehub.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IInteropCenter} from "./IInteropCenter.sol";

import {L2_MESSENGER} from "../common/L2ContractAddresses.sol";
import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER, INTEROP_OPERATION_TX_TYPE, INSERT_MSG_ADDRESS_ON_DESTINATION} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2CanonicalTransaction, L2Message, L2Log, TxStatus, InteropCallStarter, InteropCall, BundleMetadata, InteropBundle, InteropTrigger, GasFields, InteropCallRequest} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {AddressTooLow, MsgValueMismatch, Unauthorized, WrongMagicValue, BridgehubOnL1} from "../common/L1ContractErrors.sol";
import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "../common/L2ContractAddresses.sol";

import {TransientInterop} from "./TransientInterop.sol";

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
    function setAddresses(address _assetRouter) external onlyOwner {
        assetRouter = _assetRouter;
    }
    /*//////////////////////////////////////////////////////////////
                        Bundle interface
    //////////////////////////////////////////////////////////////*/

    function startBundle(uint256 _destinationChainId) public returns (bytes32 bundleId) {
        bundleId = keccak256(abi.encodePacked(bundleCount, msg.sender, _destinationChainId));
        bundleCount++;
        TransientInterop.setBundleMetadata(
            bundleId,
            BundleMetadata({
                destinationChainId: _destinationChainId,
                initiator: msg.sender,
                callCount: 0,
                totalValue: 0
            })
        );
        TransientInterop.addCallToBundle(
            bundleId,
            InteropCall({to: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, from: L2_BOOTLOADER_ADDRESS, value: 0, data: ""})// minting here to interopCaller
        );
    }

    function addCallToBundle(bytes32 _bundleId, InteropCallRequest memory _interopCallRequest) public {
        InteropCall memory interopCall;
        interopCall.to = _interopCallRequest.to;
        interopCall.data = _interopCallRequest.data;
        interopCall.value = _interopCallRequest.value;
        interopCall.from = msg.sender;
        TransientInterop.addCallToBundle(_bundleId, interopCall);
    }

    function finishAndSendBundle(bytes32 _bundleId, address _executionAddress) external payable returns (bytes32 interopBundleHash) {
        require(block.chainid != L1_CHAIN_ID, "InteropCenter: Cannot send bundle from L1");
        interopBundleHash = _finishAndSendBundle(_bundleId, _executionAddress, msg.value);
    }


    function _finishAndSendBundle(bytes32 _bundleId, address _executionAddress, uint256 _receivedMsgValue) internal returns (bytes32 interopBundleHash) {
        BundleMetadata memory bundleMetadata = TransientInterop.getBundleMetadata(_bundleId);
        if (bundleMetadata.initiator != msg.sender) {
            revert Unauthorized(msg.sender);
        }

        InteropCall[] memory interopCalls = new InteropCall[](bundleMetadata.callCount);
        for (uint256 i = 0; i < bundleMetadata.callCount; i++) {
            InteropCall memory interopCall = TransientInterop.getBundleCall(_bundleId, i);
            interopCalls[i] = interopCall;
        }

        _ensureCorrectTotalValue(
            bundleMetadata.destinationChainId,
            bundleMetadata.initiator,
            bundleMetadata.totalValue,
            _receivedMsgValue
        );

        address[] memory executionAddresses = new address[](1);
        executionAddresses[0] = _executionAddress;
        InteropBundle memory interopBundle = InteropBundle({
            destinationChainId: bundleMetadata.destinationChainId,
            calls: interopCalls,
            executionAddresses: executionAddresses,
            cancellationAddress: address(0)
        });
        bytes memory interopBundleBytes = abi.encode(interopBundle);
        interopBundleHash = keccak256(interopBundleBytes);
        if (block.chainid == L1_CHAIN_ID) {
            // we construct the L2CanonicalTransaction manually
            // when sending the trigger
            return interopBundleHash;
        } else {
            L2_MESSENGER.sendToL1(interopBundleBytes);
        }
    }

    function _ensureCorrectTotalValue(uint256 _destinationChainId, address _initiator, uint256 _totalValue, uint256 _receivedMsgValue) internal {
        if (_totalValue == 0) {
            return;
        }

        bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
        uint256 baseTokenMsgValue;
        if (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) {
            // until we sort out chain registration on L2s we assume the same base token.
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
        IAssetRouterBase(assetRouter).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
            _destinationChainId,
            tokenAssetId,
            _initiator,
            _totalValue
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Interop tx interface
    //////////////////////////////////////////////////////////////*/

    function sendInteropTrigger(InteropTrigger memory _interopTrigger) public returns(bytes32 canonicalTxHash) {
        if (block.chainid == L1_CHAIN_ID) {
            // on L1 we need to send the tx via an old interface
            revert("InteropCenter: Cannot send trigger from L1");
        }
        _sendInteropTrigger(_interopTrigger, bytes32(0), bytes32(0));
    }

    function _sendInteropTrigger(InteropTrigger memory _interopTrigger, bytes32 _feeBundleId, bytes32 _executionBundleId) internal returns (bytes32 canonicalTxHash) { 
        if (block.chainid == L1_CHAIN_ID) {
            // todo send L1->L2 txs here manually
            // we can send it as the bundles are still in transient storage, and are of the correct format.
            address zkChain = BRIDGE_HUB.getZKChain(_interopTrigger.destinationChainId);
            BridgehubL2TransactionRequest memory request = constructRequestFromTrigger(_interopTrigger, _feeBundleId, _executionBundleId);
            return IZKChain(zkChain).bridgehubRequestL2Transaction(request);
        } else {
            return L2_MESSENGER.sendToL1(abi.encode(_interopTrigger));
        }
    }

    function constructRequestFromTrigger(InteropTrigger memory _interopTrigger, bytes32 _feeBundleId, bytes32 _executionBundleId) internal returns (BridgehubL2TransactionRequest memory request) {
        // InteropCall memory feeCall_0 = TransientInterop.getBundleCall(_interopTrigger.feeBundleHash, 0);
        InteropCall memory feeCall_1 = TransientInterop.getBundleCall(_feeBundleId, 1);
        // InteropCall memory executionCall_0 = TransientInterop.getBundleCall(_interopTrigger.executionBundleHash, 0);
        InteropCall memory executionCall_1 = TransientInterop.getBundleCall(_executionBundleId, 1);
        return BridgehubL2TransactionRequest({
            sender: executionCall_1.from,
            contractL2: executionCall_1.to,
            mintValue: feeCall_1.value + executionCall_1.value,
            l2Value: executionCall_1.value,
            l2Calldata: executionCall_1.data,
            l2GasLimit: _interopTrigger.gasFields.gasLimit,
            l2GasPerPubdataByteLimit: _interopTrigger.gasFields.gasPerPubdataByteLimit,
            factoryDeps: new bytes[](0),
            refundRecipient: address(0) // todo 
        });
    }
    /*//////////////////////////////////////////////////////////////
                        EOA helpers
    //////////////////////////////////////////////////////////////*/

    function requestInterop(
        uint256 _destinationChainId,
        InteropCallStarter[] memory _feePaymentCallStarters,
        InteropCallRequest[] memory _feePaymentDirectCalls,
        InteropCallStarter[] memory _executionCallStarters,
        InteropCallRequest[] memory _executionDirectCalls,
        GasFields memory _gasFields
    ) public payable returns (bytes32 canonicalTxHash) {
        return _requestInterop(_destinationChainId, _feePaymentCallStarters, _feePaymentDirectCalls, _executionCallStarters, _executionDirectCalls, _gasFields, msg.sender);
    }

    struct ViaIRStruct {
        bytes32 feeBundleId;
        bytes32 feeBundleHash;
        bytes32 executionBundleId;
        bytes32 executionBundleHash;
    }

    function _requestInterop(
        uint256 _destinationChainId,
        InteropCallStarter[] memory _feePaymentCallStarters,
        InteropCallRequest[] memory _feePaymentDirectCalls,
        InteropCallStarter[] memory _executionCallStarters,
        InteropCallRequest[] memory _executionDirectCalls,
        GasFields memory _gasFields,
        address _sender
    ) internal returns (bytes32) {
        if (block.chainid == L1_CHAIN_ID) {
            // todo add restrictions to be L1->L2 txs compatible
        }
        ViaIRStruct memory viaIR = ViaIRStruct({
            feeBundleId: bytes32(0),
            feeBundleHash: bytes32(0),
            executionBundleId: bytes32(0),
            executionBundleHash: bytes32(0)
        });
        viaIR.feeBundleId = startBundle(_destinationChainId);
        uint256 feeValue = 0;
        uint256 ethIsBaseTokenMultiplier;
        { 
            bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId); 
            ethIsBaseTokenMultiplier = (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) ? 1 : 0;
        }
        for (uint256 i = 0; i < _feePaymentCallStarters.length; i++) {
            InteropCallStarter memory callStarter = _feePaymentCallStarters[i];
            feeValue += callStarter.value;
            IL1AssetRouter(callStarter.to).bridgehubAddCallToBundle{value: callStarter.value}(
                _destinationChainId,
                viaIR.feeBundleId,
                _sender,
                callStarter.requestedInteropCallValue,
                callStarter.data
            );
        }
        for (uint256 i = 0; i < _feePaymentDirectCalls.length; i++) {
            feeValue += _feePaymentDirectCalls[i].value * ethIsBaseTokenMultiplier;
            InteropCallRequest memory directCall = _feePaymentDirectCalls[i];
            addCallToBundle(viaIR.feeBundleId, directCall);
        }
        viaIR.feeBundleHash = _finishAndSendBundle(viaIR.feeBundleId, _sender, feeValue);

        viaIR.executionBundleId = startBundle(_destinationChainId);
        for (uint256 i = 0; i < _executionCallStarters.length; i++) {
            InteropCallStarter memory callStarter = _executionCallStarters[i];
            IL1AssetRouter(callStarter.to).bridgehubAddCallToBundle{value: callStarter.value}(
                _destinationChainId,
                viaIR.executionBundleId,
                _sender,
                callStarter.requestedInteropCallValue,
                callStarter.data
            );
        }
        for (uint256 i = 0; i < _executionDirectCalls.length; i++) {
            InteropCallRequest memory directCall = _executionDirectCalls[i];
            addCallToBundle(viaIR.executionBundleId, directCall);
        }
        bytes32 executionBundleHash = _finishAndSendBundle(viaIR.executionBundleId, address(0), msg.value - feeValue);
        InteropTrigger memory interopTrigger = InteropTrigger({sender: _sender, destinationChainId: _destinationChainId, feeBundleHash: viaIR.feeBundleHash, executionBundleHash: executionBundleHash, gasFields: _gasFields});

        return _sendInteropTrigger(interopTrigger, viaIR.feeBundleId, viaIR.executionBundleId);
    }

    /// the new version of two bridges, i.e. the minimal interopTx with a contract call and gas. 
    function requestInteropSingleCall(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) public payable returns (bytes32 canonicalTxHash) {
        return _requestInteropSingleCall(_request, msg.sender);
    }
    
    function _requestInteropSingleCall(
        L2TransactionRequestTwoBridgesOuter calldata _request,
        address _sender
    ) internal returns (bytes32 canonicalTxHash) {
        InteropCallRequest[] memory feePaymentDirectCalls = new InteropCallRequest[](1);
        require(_request.mintValue > _request.l2Value, "InteropCenter: mintValue must be greater than l2Value");
        feePaymentDirectCalls[0] = InteropCallRequest({
            to: INSERT_MSG_ADDRESS_ON_DESTINATION,
            data: "",
            value: _request.mintValue - _request.l2Value
        });
        InteropCallStarter[] memory executionCallStarters = new InteropCallStarter[](1);
        executionCallStarters[0] = InteropCallStarter({
            to: _request.secondBridgeAddress,
            data: _request.secondBridgeCalldata,
            value: _request.secondBridgeValue,
            requestedInteropCallValue: _request.l2Value
        });
        return _requestInterop(
            _request.chainId,
            new InteropCallStarter[](0),
            feePaymentDirectCalls,
            executionCallStarters,
            new InteropCallRequest[](0),
            GasFields({
                gasLimit: _request.l2GasLimit,
                gasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                refundRecipient: _request.refundRecipient
            }),
            _sender
        );
    }

    /// the new version of two bridges, i.e. the minimal interopTx with a contract call and gas. 
    function requestInteropSingleDirectCall(
        L2TransactionRequestDirect calldata _request
    ) public payable returns (bytes32 canonicalTxHash) {
        return _requestInteropSingleDirectCall(_request, msg.sender);
    }
    
    function _requestInteropSingleDirectCall(
        L2TransactionRequestDirect calldata _request,
        address _sender
    ) internal returns (bytes32 canonicalTxHash) {
        InteropCallRequest[] memory feePaymentDirectCalls = new InteropCallRequest[](1);
        require(_request.mintValue > _request.l2Value, "InteropCenter: mintValue must be greater than l2Value");
        feePaymentDirectCalls[0] = InteropCallRequest({
            to: INSERT_MSG_ADDRESS_ON_DESTINATION,
            data: "0x",
            value: _request.mintValue - _request.l2Value
        });
        InteropCallRequest[] memory executionDirectCall = new InteropCallRequest[](1);
        executionDirectCall[0] = InteropCallRequest({
            to: _request.l2Contract,
            data: _request.l2Calldata,
            value: _request.l2Value
        });
        return _requestInterop(
            _request.chainId,
            new InteropCallStarter[](0),
            feePaymentDirectCalls,
            new InteropCallStarter[](0),
            executionDirectCall,
            GasFields({
                gasLimit: _request.l2GasLimit,
                gasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                refundRecipient: _request.refundRecipient
            }),
            _sender
        );
    }

    function addCallToBundleFromRequest(bytes32 _bundleId, uint256 _value, L2TransactionRequestTwoBridgesInner memory _request) public {
        addCallToBundle(_bundleId, InteropCallRequest({to: _request.l2Contract, value: _value, data: _request.l2Calldata}));
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
        // return _requestL2TransactionDirect(msg.sender, _request);
        return _requestInteropSingleDirectCall(_request, msg.sender);
    }

    function requestL2TransactionDirectSender(
        address _sender,
        L2TransactionRequestDirect calldata _request
    ) external payable override onlyBridgehub returns (bytes32 canonicalTxHash) {
        // return _requestL2TransactionDirect(_sender, _request);
        return _requestInteropSingleDirectCall(_request, _sender);
    }

    /// @notice the mailbox is called directly after the assetRouter received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the nativeTokenVault.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token.
    /// In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    function _requestL2TransactionDirect(
        address _sender,
        L2TransactionRequestDirect calldata _request
    ) internal nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
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
            IAssetRouterBase(assetRouter).bridgehubDepositBaseToken{value: msg.value}(
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
        // note this is a temporary hack so that I don't have to migrate all the tooling to the new interface
        // return _requestL2TransactionTwoBridges(msg.sender, false, _request);
        return _requestInteropSingleCall(_request, msg.sender);
    }

    function requestL2TransactionTwoBridgesSender(
        address _sender,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override onlyBridgehub returns (bytes32 canonicalTxHash) {
        // note this is a temporary hack so that I don't have to migrate all the tooling to the new interface
        // return _requestL2TransactionTwoBridges(_sender, true, _request);
        return _requestInteropSingleCall(_request, _sender);
    }

    function _requestL2TransactionTwoBridges(
        address _sender, bool _routeViaBridgehub,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) internal nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        if (_request.secondBridgeAddress <= BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS) {
            revert AddressTooLow(_request.secondBridgeAddress);
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
            IAssetRouterBase(assetRouter).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
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
            })
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
        BridgehubL2TransactionRequest memory _request
    ) internal returns (bytes32 canonicalTxHash) {
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, msg.sender);
        _request.refundRecipient = refundRecipient;
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        if (zkChain != address(0)) {
            canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(_request);
        } else {
            /// Fixme this does not have a unique hash atm.
            // canonicalTxHash = L2_MESSENGER.sendToL1(abi.encode(_request));
            // canonicalTxHash = L2_MESSENGER.sendToL1(abi.encode(transaction));

            // solhint-disable-next-line func-named-parameters
            // emit IMailbox.NewPriorityRequest(0, canonicalTxHash, 0, transaction, _request.factoryDeps);
        }
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
        if (L1_CHAIN_ID == block.chainid) {
            revert BridgehubOnL1();
        }
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
