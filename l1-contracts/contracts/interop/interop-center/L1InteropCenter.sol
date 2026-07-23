// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    MIN_CROSS_CHAIN_SENDER_ADDRESS,
    ETH_TOKEN_ADDRESS,
    SUPPORTED_L1_INTEROP_ATTRIBUTES,
    INDIRECT_CALL_MAGIC_VALUE
} from "../../common/Config.sol";
import {ChainIdNotRegistered, MsgValueMismatch, WrongMagicValue, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {CrossChainSenderAddressTooLow} from "../../core/bridgehub/L1BridgehubErrors.sol";
import {BridgehubL2TransactionRequest, InteropCallStarter} from "../../common/Messaging.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

import {IndirectCallRequest} from "../../core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {IAssetRouterShared} from "../../bridge/asset-router/IAssetRouterShared.sol";
import {IL1CrossChainSender} from "../../bridge/interfaces/IL1CrossChainSender.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";

import {AttributesDecoder} from "../AttributesDecoder.sol";
import {IERC7786Attributes} from "../IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "../IERC7786GatewaySource.sol";
import {IL1InteropCenter, L1MessageAttributes} from "../IL1InteropCenter.sol";
import {InteropCenterBase} from "./InteropCenterBase.sol";
import {
    AttributeAlreadySet,
    AttributeViolatesRestriction,
    FactoryDepsNotAllowedForIndirectCall,
    L1ToL2TransactionParamsMissing,
    SingleCallBundleRequired
} from "../InteropErrors.sol";

/// @title L1InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract is the L1 counterpart of the L2 `L2InteropCenter`: the single user-facing entry point for
/// sending messages from L1 to the ZK chains, exposed through the ERC-7786 `sendMessage` interface.
/// @dev Unlike on L2s, where messages are delivered as interop bundles verified against interop roots,
/// messages sent from L1 are delivered through the priority queue: every `sendMessage` call results in an
/// L1->L2 priority transaction requested on the destination chain's Mailbox. Because of that, every message
/// must carry the `l1ToL2TransactionParams` attribute that parameterizes the priority transaction.
/// @dev Two modes are supported, replacing the former `L1Bridgehub.requestL2TransactionDirect` and
/// `L1Bridgehub.requestL2TransactionTwoBridges` entry points:
/// - Direct calls (no `indirectCall` attribute): the message recipient is called with the given payload.
///   This assumes that either ether is the base token or the caller has approved the mintValue allowance for
///   the native token vault. In case allowance is provided to the asset router, it will be transferred to NTV.
/// - Indirect calls (`indirectCall` attribute set): the recipient is an L1 cross-chain sender
///   (a "second bridge", e.g. the L1 asset router) that receives the payload on L1 and constructs the actual
///   destination-side call. This is the flow used for token deposits: each contract handling user ERC20 tokens
///   needs its own approvals, and this mode lets the user approve, for each token, only its respective bridge.
/// @dev The contract relies on the L1 Bridgehub as the registry of chains and base tokens; the downstream
/// contracts (asset router, cross-chain senders and the chains' Mailboxes) authorize this contract by
/// resolving `interopCenter()` on the Bridgehub.
contract L1InteropCenter is IL1InteropCenter, InteropCenterBase {
    enum L1AttributeParsingRestrictions {
        OnlyCallAttributes,
        OnlyBundleAttributes,
        CallAndBundleAttributes
    }

    /// @notice The L1 Bridgehub, used as the registry of chains, base tokens and ZK chain addresses.
    IL1Bridgehub public immutable override BRIDGE_HUB;

    /// @notice The asset id of Eth, used for base token value accounting.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice To avoid parity hack.
    constructor(IL1Bridgehub _bridgehub, address _owner) reentrancyGuardInitializer {
        if (address(_bridgehub) == address(0)) {
            revert ZeroAddress();
        }
        BRIDGE_HUB = _bridgehub;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _disableInitializers();
        _transferOwnership(_owner);
    }

    /// @inheritdoc IL1InteropCenter
    function initialize(address _owner) external override reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                    L1InteropCenter entry points
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends a single ERC-7786 message from L1 to a ZK chain via an L1->L2 priority transaction.
    /// @param _recipient ERC-7930 address corresponding to the destination of the message. The chain reference
    /// must correspond to the destination chain. For direct calls the address part is the contract to be called
    /// on the destination chain; for indirect calls it is the L1 cross-chain sender (e.g. the L1 asset router).
    /// @param _payload The payload of the message. For direct calls it is the calldata of the destination-side
    /// call; for indirect calls it is the data passed to the L1 cross-chain sender.
    /// @param _attributes The ERC-7786 attributes of the message. The `l1ToL2TransactionParams` attribute is
    /// required; `interopCallValue`, `indirectCall` and `factoryDeps` (direct calls only) are optional.
    /// @return sendId The canonical hash of the L1->L2 priority transaction that delivers the message.
    function _sendMessage(bytes calldata _recipient, bytes calldata _payload, bytes[] calldata _attributes)
        internal
        override
        returns (bytes32 sendId)
    {
        (uint256 destinationChainId, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_recipient);

        L1MessageAttributes memory attributes = parseL1Attributes(_attributes);
        sendId = _sendSingleCall(destinationChainId, recipientAddress, _payload, attributes, _attributes);
    }

    /// @dev L1 accepts the shared bundle interface but delivers exactly one call as one priority transaction.
    function _sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) internal override returns (bytes32 sendId) {
        uint256 callCount = _callStarters.length;
        require(callCount == 1, SingleCallBundleRequired(callCount));

        _ensureEmptyAddress(_destinationChainId);
        // slither-disable-next-line unused-return
        (uint256 destinationChainId,) = InteroperableAddress.parseEvmV1Calldata(_destinationChainId);

        InteropCallStarter calldata callStarter = _callStarters[0];
        _ensureEmptyChainReference(callStarter.to);
        // slither-disable-next-line unused-return
        (, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(callStarter.to);

        L1MessageAttributes memory attributes =
            _parseL1Attributes(_bundleAttributes, L1AttributeParsingRestrictions.OnlyBundleAttributes);
        L1MessageAttributes memory callAttributes =
            _parseL1Attributes(callStarter.callAttributes, L1AttributeParsingRestrictions.OnlyCallAttributes);
        attributes.interopCallValue = callAttributes.interopCallValue;
        attributes.indirectCall = callAttributes.indirectCall;
        attributes.indirectCallMessageValue = callAttributes.indirectCallMessageValue;

        sendId = _sendSingleCall(
            destinationChainId, recipientAddress, callStarter.data, attributes, callStarter.callAttributes
        );
    }

    function _sendSingleCall(
        uint256 _destinationChainId,
        address _recipientAddress,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes,
        bytes[] calldata _eventAttributes
    ) private returns (bytes32 sendId) {
        address actualRecipient;
        if (_attributes.indirectCall) {
            require(_attributes.factoryDeps.length == 0, FactoryDepsNotAllowedForIndirectCall());
        }

        IZKChain zkChain = _getZKChain(_destinationChainId);
        if (_attributes.indirectCall) {
            (sendId, actualRecipient) = _requestL2TransactionIndirect({
                _destinationChainId: _destinationChainId,
                _zkChain: zkChain,
                _secondBridgeAddress: _recipientAddress,
                _payload: _payload,
                _attributes: _attributes
            });
        } else {
            actualRecipient = _recipientAddress;
            sendId = _requestL2TransactionDirect({
                _destinationChainId: _destinationChainId,
                _zkChain: zkChain,
                _l2Contract: _recipientAddress,
                _payload: _payload,
                _attributes: _attributes
            });
        }

        // For indirect calls the actual recipient is the destination-side contract constructed by the
        // cross-chain sender, consistent with the `MessageSent` semantics of the L2InteropCenter.
        emit MessageSent({
            sendId: sendId,
            sender: InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
            recipient: InteroperableAddress.formatEvmV1(_destinationChainId, actualRecipient),
            payload: _payload,
            value: _attributes.interopCallValue,
            attributes: _eventAttributes
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits the base token and requests the L1->L2 transaction directly.
    function _requestL2TransactionDirect(
        uint256 _destinationChainId,
        IZKChain _zkChain,
        address _l2Contract,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash) {
        {
            bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                if (msg.value != _attributes.mintValue) {
                    revert MsgValueMismatch(_attributes.mintValue, msg.value);
                }
            } else {
                if (msg.value != 0) {
                    revert MsgValueMismatch(0, msg.value);
                }
            }

            // slither-disable-next-line arbitrary-send-eth
            IAssetRouterShared(address(BRIDGE_HUB.assetRouter())).bridgehubDepositBaseToken{value: msg.value}(
                _destinationChainId, tokenAssetId, msg.sender, _attributes.mintValue
            );
        }

        canonicalTxHash = _sendRequest(
            _zkChain,
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _l2Contract,
                mintValue: _attributes.mintValue,
                l2Value: _attributes.interopCallValue,
                l2Calldata: _payload,
                l2GasLimit: _attributes.l2GasLimit,
                l2GasPerPubdataByteLimit: _attributes.l2GasPerPubdataByteLimit,
                factoryDeps: _attributes.factoryDeps,
                refundRecipient: _attributes.refundRecipient
            })
        );
    }

    /// @notice Deposits the base token, calls the second bridge (the cross-chain sender) which returns the
    /// actual destination-side transaction, requests it, and lets the second bridge confirm the request.
    /// @return canonicalTxHash The canonical hash of the requested L1->L2 transaction.
    /// @return l2Contract The destination-side contract of the L2 transaction constructed by the second bridge.
    function _requestL2TransactionIndirect(
        uint256 _destinationChainId,
        IZKChain _zkChain,
        address _secondBridgeAddress,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash, address l2Contract) {
        if (_secondBridgeAddress <= MIN_CROSS_CHAIN_SENDER_ADDRESS) {
            revert CrossChainSenderAddressTooLow(_secondBridgeAddress, MIN_CROSS_CHAIN_SENDER_ADDRESS);
        }

        {
            bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
            uint256 baseTokenMsgValue;
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                uint256 expectedValue = _attributes.mintValue + _attributes.indirectCallMessageValue;
                if (msg.value != expectedValue) {
                    revert MsgValueMismatch(expectedValue, msg.value);
                }
                baseTokenMsgValue = _attributes.mintValue;
            } else {
                if (msg.value != _attributes.indirectCallMessageValue) {
                    revert MsgValueMismatch(_attributes.indirectCallMessageValue, msg.value);
                }
                baseTokenMsgValue = 0;
            }

            // slither-disable-next-line arbitrary-send-eth
            IAssetRouterShared(address(BRIDGE_HUB.assetRouter())).bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _destinationChainId, tokenAssetId, msg.sender, _attributes.mintValue
            );
        }

        // slither-disable-next-line arbitrary-send-eth
        IndirectCallRequest memory outputRequest = IL1CrossChainSender(_secondBridgeAddress)
        .initiateIndirectCall{value: _attributes.indirectCallMessageValue}(
            _destinationChainId, msg.sender, _attributes.interopCallValue, _payload
        );

        if (outputRequest.magicValue != INDIRECT_CALL_MAGIC_VALUE) {
            revert WrongMagicValue(uint256(INDIRECT_CALL_MAGIC_VALUE), uint256(outputRequest.magicValue));
        }

        l2Contract = outputRequest.l2Contract;

        canonicalTxHash = _sendRequest(
            _zkChain,
            BridgehubL2TransactionRequest({
                sender: _secondBridgeAddress,
                contractL2: outputRequest.l2Contract,
                mintValue: _attributes.mintValue,
                l2Value: _attributes.interopCallValue,
                l2Calldata: outputRequest.l2Calldata,
                l2GasLimit: _attributes.l2GasLimit,
                l2GasPerPubdataByteLimit: _attributes.l2GasPerPubdataByteLimit,
                factoryDeps: outputRequest.factoryDeps,
                refundRecipient: _attributes.refundRecipient
            })
        );

        IL1CrossChainSender(_secondBridgeAddress)
            .confirmL2Transaction(_destinationChainId, outputRequest.txDataHash, canonicalTxHash);
    }

    /// @notice Estimates the base cost (in the destination chain's base token) of an L1->L2 transaction.
    /// @dev Forwards to the destination chain's Mailbox, so that integrators of the send flow never
    /// need to interact with any contract other than the L1InteropCenter.
    /// @param _chainId the chainId of the destination chain
    /// @param _gasPrice the L1 gas price to estimate with
    /// @param _l2GasLimit the gas limit of the L2 transaction
    /// @param _l2GasPerPubdataByteLimit the maximum amount of L2 gas charged per pubdata byte
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view override returns (uint256) {
        return _getZKChain(_chainId).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /// @notice Sends the request to the destination ZK chain's Mailbox.
    /// @param _zkChain the destination ZK chain
    /// @param _request the request
    /// @return canonicalTxHash the canonical transaction hash
    function _sendRequest(IZKChain _zkChain, BridgehubL2TransactionRequest memory _request)
        private
        returns (bytes32 canonicalTxHash)
    {
        // Although the aliasing might happen in the Mailbox, we still want to determine the refund recipient
        // here, as the Mailbox won't have the original caller.
        _request.refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);
        canonicalTxHash = _zkChain.bridgehubRequestL2Transaction(_request);
    }

    /// @notice Resolves a registered ZK chain or reverts before any value-moving external calls are made.
    function _getZKChain(uint256 _chainId) private view returns (IZKChain zkChain) {
        zkChain = IZKChain(BRIDGE_HUB.getZKChain(_chainId));
        if (address(zkChain) == address(0)) {
            revert ChainIdNotRegistered(_chainId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ERC 7786
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1InteropCenter
    function parseL1Attributes(bytes[] calldata _attributes)
        public
        pure
        override
        returns (L1MessageAttributes memory l1MessageAttributes)
    {
        l1MessageAttributes = _parseL1Attributes(_attributes, L1AttributeParsingRestrictions.CallAndBundleAttributes);
    }

    function _parseL1Attributes(bytes[] calldata _attributes, L1AttributeParsingRestrictions _restriction)
        private
        pure
        returns (L1MessageAttributes memory l1MessageAttributes)
    {
        bytes4[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
        // We can only pass each attribute once.
        bool[] memory attributeUsed = new bool[](ATTRIBUTE_SELECTORS.length);

        // The `l1ToL2TransactionParams` attribute is required, since without it the L1->L2 priority
        // transaction that delivers the message can not be formed.
        bool hasL1ToL2TransactionParams = false;

        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            bytes4 selector = bytes4(_attributes[i]);

            if (selector == IERC7786Attributes.interopCallValue.selector) {
                require(
                    _restriction != L1AttributeParsingRestrictions.OnlyBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                require(!attributeUsed[0], AttributeAlreadySet(selector));
                attributeUsed[0] = true;
                l1MessageAttributes.interopCallValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (selector == IERC7786Attributes.indirectCall.selector) {
                require(
                    _restriction != L1AttributeParsingRestrictions.OnlyBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                require(!attributeUsed[1], AttributeAlreadySet(selector));
                attributeUsed[1] = true;
                l1MessageAttributes.indirectCall = true;
                l1MessageAttributes.indirectCallMessageValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (selector == IERC7786Attributes.l1ToL2TransactionParams.selector) {
                require(
                    _restriction != L1AttributeParsingRestrictions.OnlyCallAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                require(!attributeUsed[2], AttributeAlreadySet(selector));
                attributeUsed[2] = true;
                hasL1ToL2TransactionParams = true;
                (
                    l1MessageAttributes.mintValue,
                    l1MessageAttributes.l2GasLimit,
                    l1MessageAttributes.l2GasPerPubdataByteLimit,
                    l1MessageAttributes.refundRecipient
                ) = AttributesDecoder.decodeL1ToL2TransactionParams(_attributes[i]);
            } else if (selector == IERC7786Attributes.factoryDeps.selector) {
                require(
                    _restriction != L1AttributeParsingRestrictions.OnlyCallAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                require(!attributeUsed[3], AttributeAlreadySet(selector));
                attributeUsed[3] = true;
                l1MessageAttributes.factoryDeps = AttributesDecoder.decodeBytesArray(_attributes[i]);
            } else {
                revert IERC7786GatewaySource.UnsupportedAttribute(selector);
            }
        }

        require(
            _restriction == L1AttributeParsingRestrictions.OnlyCallAttributes || hasL1ToL2TransactionParams,
            L1ToL2TransactionParamsMissing()
        );
    }

    /// @notice Checks if the attribute selector is supported by the L1InteropCenter.
    /// @param _attributeSelector The attribute selector to check.
    /// @return True if the attribute selector is supported, false otherwise.
    function supportsAttribute(bytes4 _attributeSelector) external pure override returns (bool) {
        bytes4[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
        uint256 attributeSelectorsLength = ATTRIBUTE_SELECTORS.length;
        for (uint256 i = 0; i < attributeSelectorsLength; ++i) {
            if (_attributeSelector == ATTRIBUTE_SELECTORS[i]) {
                return true;
            }
        }
        return false;
    }

    /// @notice Returns the attribute selectors supported by the L1InteropCenter.
    /// @return The attribute selectors supported by the L1InteropCenter.
    function _getERC7786AttributeSelectors() internal pure returns (bytes4[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory) {
        return [
            IERC7786Attributes.interopCallValue.selector,
            IERC7786Attributes.indirectCall.selector,
            IERC7786Attributes.l1ToL2TransactionParams.selector,
            IERC7786Attributes.factoryDeps.selector
        ];
    }
}
