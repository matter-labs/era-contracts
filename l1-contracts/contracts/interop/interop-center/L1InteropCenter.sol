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

import {IndirectCallRequest} from "../../common/Messaging.sol";
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
/// @notice Sends L1 messages through the Mailbox; see {protocol-docs/l1-interop-center.md}.
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

    /// @notice Locks the implementation and fixes the L1 registry.
    /// @param _bridgehub The L1 Bridgehub registry.
    constructor(IL1Bridgehub _bridgehub) reentrancyGuardInitializer {
        if (address(_bridgehub) == address(0)) {
            revert ZeroAddress();
        }
        BRIDGE_HUB = _bridgehub;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _disableInitializers();
    }

    /// @inheritdoc IL1InteropCenter
    function initialize(address _owner) external override reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                    L1InteropCenter entry points
    //////////////////////////////////////////////////////////////*/

    function _sendMessage(
        bytes calldata _recipient,
        bytes calldata _payload,
        bytes[] calldata _attributes
    ) internal override returns (bytes32 sendId) {
        (uint256 destinationChainId, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_recipient);

        L1MessageAttributes memory attributes = parseL1Attributes(_attributes);
        sendId = _sendSingleCall({
            _destinationChainId: destinationChainId,
            _recipientAddress: recipientAddress,
            _payload: _payload,
            _attributes: attributes,
            _eventAttributes: _attributes
        });
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
        (uint256 destinationChainId, ) = InteroperableAddress.parseEvmV1Calldata(_destinationChainId);

        InteropCallStarter calldata callStarter = _callStarters[0];
        _ensureEmptyChainReference(callStarter.to);
        // slither-disable-next-line unused-return
        (, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(callStarter.to);

        L1MessageAttributes memory attributes = _parseL1Attributes(
            _bundleAttributes,
            L1AttributeParsingRestrictions.OnlyBundleAttributes
        );
        L1MessageAttributes memory callAttributes = _parseL1Attributes(
            callStarter.callAttributes,
            L1AttributeParsingRestrictions.OnlyCallAttributes
        );
        attributes.interopCallValue = callAttributes.interopCallValue;
        attributes.indirectCall = callAttributes.indirectCall;
        attributes.indirectCallMessageValue = callAttributes.indirectCallMessageValue;

        sendId = _sendSingleCall({
            _destinationChainId: destinationChainId,
            _recipientAddress: recipientAddress,
            _payload: callStarter.data,
            _attributes: attributes,
            _eventAttributes: callStarter.callAttributes
        });
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
            require(!_attributes.factoryDepsProvided, FactoryDepsNotAllowedForIndirectCall());
        }

        IZKChain zkChain = _getZKChain(_destinationChainId);
        if (_attributes.indirectCall) {
            (sendId, actualRecipient) = _sendIndirect({
                _destinationChainId: _destinationChainId,
                _zkChain: zkChain,
                _crossChainSender: _recipientAddress,
                _payload: _payload,
                _attributes: _attributes
            });
        } else {
            actualRecipient = _recipientAddress;
            sendId = _sendDirect({
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
    function _sendDirect(
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
                _destinationChainId,
                tokenAssetId,
                msg.sender,
                _attributes.mintValue
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

    /// @notice Funds and sends an indirect request, then confirms its canonical hash.
    /// @return canonicalTxHash The canonical hash of the requested L1->L2 transaction.
    /// @return l2Contract The destination-side contract of the L2 transaction constructed by the cross-chain sender.
    function _sendIndirect(
        uint256 _destinationChainId,
        IZKChain _zkChain,
        address _crossChainSender,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash, address l2Contract) {
        if (_crossChainSender <= MIN_CROSS_CHAIN_SENDER_ADDRESS) {
            revert CrossChainSenderAddressTooLow(_crossChainSender, MIN_CROSS_CHAIN_SENDER_ADDRESS);
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
                _destinationChainId,
                tokenAssetId,
                msg.sender,
                _attributes.mintValue
            );
        }

        // slither-disable-next-line arbitrary-send-eth
        IndirectCallRequest memory outputRequest = IL1CrossChainSender(_crossChainSender).initiateIndirectCall{
            value: _attributes.indirectCallMessageValue
        }(_destinationChainId, msg.sender, _attributes.interopCallValue, _payload);

        if (outputRequest.magicValue != INDIRECT_CALL_MAGIC_VALUE) {
            revert WrongMagicValue(uint256(INDIRECT_CALL_MAGIC_VALUE), uint256(outputRequest.magicValue));
        }

        l2Contract = outputRequest.l2Contract;

        canonicalTxHash = _sendRequest(
            _zkChain,
            BridgehubL2TransactionRequest({
                sender: _crossChainSender,
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

        IL1CrossChainSender(_crossChainSender).confirmL2Transaction(
            _destinationChainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }

    /// @inheritdoc IL1InteropCenter
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
    function _sendRequest(
        IZKChain _zkChain,
        BridgehubL2TransactionRequest memory _request
    ) private returns (bytes32 canonicalTxHash) {
        // Although the aliasing might happen in the Mailbox, we still want to determine the refund recipient
        // here, as the Mailbox won't have the original caller.
        // slither-disable-next-line unused-return
        (_request.refundRecipient, ) = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);
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
    function parseL1Attributes(
        bytes[] calldata _attributes
    ) public pure override returns (L1MessageAttributes memory l1MessageAttributes) {
        l1MessageAttributes = _parseL1Attributes(_attributes, L1AttributeParsingRestrictions.CallAndBundleAttributes);
    }

    function _parseL1Attributes(
        bytes[] calldata _attributes,
        L1AttributeParsingRestrictions _restriction
    ) private pure returns (L1MessageAttributes memory l1MessageAttributes) {
        bool[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory attributeUsed;

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
                l1MessageAttributes.factoryDepsProvided = true;
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

    /// @inheritdoc IERC7786GatewaySource
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
        return
            [
                IERC7786Attributes.interopCallValue.selector,
                IERC7786Attributes.indirectCall.selector,
                IERC7786Attributes.l1ToL2TransactionParams.selector,
                IERC7786Attributes.factoryDeps.selector
            ];
    }
}
