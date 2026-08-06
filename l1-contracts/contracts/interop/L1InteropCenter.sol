// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SUPPORTED_L1_INTEROP_ATTRIBUTES} from "../common/Config.sol";
import {ChainIdNotRegistered, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "../core/bridgehub/IBridgehubBase.sol";

import {AttributesDecoder} from "./AttributesDecoder.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IL1InteropCenter, L1MessageAttributes} from "./IL1InteropCenter.sol";
import {
    AttributeAlreadySet,
    FactoryDepsNotAllowedForIndirectCall,
    L1ToL2TransactionParamsMissing
} from "./InteropErrors.sol";

/// @title L1InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Exposes L1->L2 requests through the ERC-7786 `sendMessage` interface by relaying them to the
/// Bridgehub, which keeps performing the request itself. Both Bridgehub request modes remain available
/// and unchanged; this contract is an additional, permissionless entry point in front of them.
/// See {protocol-docs/l1-interop-center.md}.
contract L1InteropCenter is IL1InteropCenter, ReentrancyGuard {
    /// @inheritdoc IL1InteropCenter
    IL1Bridgehub public immutable override BRIDGE_HUB;

    constructor(IL1Bridgehub _bridgehub) reentrancyGuardInitializer {
        require(address(_bridgehub) != address(0), ZeroAddress());
        BRIDGE_HUB = _bridgehub;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-7786 entry point
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends a single ERC-7786 message from L1 to a ZK chain as an L1->L2 priority transaction.
    /// @param _recipient ERC-7930 address of the destination. For direct calls the address part is the contract
    /// called on the destination chain; for indirect calls it is the L1 cross-chain sender that constructs it.
    /// @param _payload For direct calls the destination-side calldata; for indirect calls the data passed to the
    /// cross-chain sender on L1.
    /// @param _attributes The ERC-7786 attributes of the message. `l1ToL2TransactionParams` is required;
    /// `interopCallValue`, `indirectCall` and `factoryDeps` (direct calls only) are optional.
    /// @return sendId The canonical hash of the L1->L2 priority transaction that delivers the message.
    function sendMessage(
        bytes calldata _recipient,
        bytes calldata _payload,
        bytes[] calldata _attributes
    ) external payable override nonReentrant returns (bytes32 sendId) {
        (uint256 destinationChainId, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_recipient);
        // A chain-only ERC-7930 encoding parses to address(0), which would take the funds yet never be executable.
        require(recipientAddress != address(0), ZeroAddress());
        require(BRIDGE_HUB.getZKChain(destinationChainId) != address(0), ChainIdNotRegistered(destinationChainId));

        L1MessageAttributes memory attributes = parseL1Attributes(_attributes);

        if (attributes.indirectCall) {
            sendId = _relayIndirectRequest(destinationChainId, recipientAddress, _payload, attributes);
        } else {
            sendId = _relayDirectRequest(destinationChainId, recipientAddress, _payload, attributes);
        }

        emit MessageSent({
            sendId: sendId,
            sender: InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
            recipient: _recipient,
            payload: _payload,
            value: attributes.interopCallValue,
            attributes: _attributes
        });
    }

    /// @inheritdoc IL1InteropCenter
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view override returns (uint256) {
        return BRIDGE_HUB.l2TransactionBaseCost(_chainId, _gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /*//////////////////////////////////////////////////////////////
                            Relaying
    //////////////////////////////////////////////////////////////*/

    /// @dev Relays a direct call, mapping the message onto the Bridgehub's direct request. The Bridgehub is
    /// told which account the request is made for, so the message sender provides the base token and becomes
    /// the sender of the L1->L2 transaction.
    function _relayDirectRequest(
        uint256 _destinationChainId,
        address _l2Contract,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash) {
        canonicalTxHash = BRIDGE_HUB.requestL2TransactionDirectFor{value: msg.value}(
            msg.sender,
            L2TransactionRequestDirect({
                chainId: _destinationChainId,
                mintValue: _attributes.mintValue,
                l2Contract: _l2Contract,
                l2Value: _attributes.interopCallValue,
                l2Calldata: _payload,
                l2GasLimit: _attributes.l2GasLimit,
                l2GasPerPubdataByteLimit: _attributes.l2GasPerPubdataByteLimit,
                factoryDeps: _attributes.factoryDeps,
                refundRecipient: _attributes.refundRecipient
            })
        );
    }

    /// @dev Relays an indirect call, mapping the message onto the Bridgehub's two-bridges request. The message
    /// sender is passed on to the cross-chain sender as the depositor, so deposits stay recoverable by them.
    function _relayIndirectRequest(
        uint256 _destinationChainId,
        address _crossChainSender,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash) {
        require(_attributes.factoryDeps.length == 0, FactoryDepsNotAllowedForIndirectCall());

        canonicalTxHash = BRIDGE_HUB.requestL2TransactionTwoBridgesFor{value: msg.value}(
            msg.sender,
            L2TransactionRequestTwoBridgesOuter({
                chainId: _destinationChainId,
                mintValue: _attributes.mintValue,
                l2Value: _attributes.interopCallValue,
                l2GasLimit: _attributes.l2GasLimit,
                l2GasPerPubdataByteLimit: _attributes.l2GasPerPubdataByteLimit,
                refundRecipient: _attributes.refundRecipient,
                secondBridgeAddress: _crossChainSender,
                secondBridgeValue: _attributes.indirectCallMessageValue,
                secondBridgeCalldata: _payload
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Attributes
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1InteropCenter
    function parseL1Attributes(
        bytes[] calldata _attributes
    ) public pure override returns (L1MessageAttributes memory l1MessageAttributes) {
        bool[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory attributeUsed;
        bool hasL1ToL2TransactionParams = false;

        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            bytes4 selector = bytes4(_attributes[i]);

            if (selector == IERC7786Attributes.interopCallValue.selector) {
                require(!attributeUsed[0], AttributeAlreadySet(selector));
                attributeUsed[0] = true;
                l1MessageAttributes.interopCallValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (selector == IERC7786Attributes.indirectCall.selector) {
                require(!attributeUsed[1], AttributeAlreadySet(selector));
                attributeUsed[1] = true;
                l1MessageAttributes.indirectCall = true;
                l1MessageAttributes.indirectCallMessageValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (selector == IERC7786Attributes.l1ToL2TransactionParams.selector) {
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
                require(!attributeUsed[3], AttributeAlreadySet(selector));
                attributeUsed[3] = true;
                l1MessageAttributes.factoryDeps = AttributesDecoder.decodeBytesArray(_attributes[i]);
            } else {
                revert IERC7786GatewaySource.UnsupportedAttribute(selector);
            }
        }

        // Without these parameters the L1->L2 priority transaction that delivers the message can not be formed.
        require(hasL1ToL2TransactionParams, L1ToL2TransactionParamsMissing());
    }

    /// @notice Checks whether the attribute selector is supported by this contract.
    /// @param _attributeSelector The attribute selector to check.
    function supportsAttribute(bytes4 _attributeSelector) external pure override returns (bool) {
        bytes4[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory attributeSelectors = _supportedAttributeSelectors();
        for (uint256 i = 0; i < SUPPORTED_L1_INTEROP_ATTRIBUTES; ++i) {
            if (_attributeSelector == attributeSelectors[i]) {
                return true;
            }
        }
        return false;
    }

    function _supportedAttributeSelectors()
        private
        pure
        returns (bytes4[SUPPORTED_L1_INTEROP_ATTRIBUTES] memory selectors)
    {
        selectors = [
            IERC7786Attributes.interopCallValue.selector,
            IERC7786Attributes.indirectCall.selector,
            IERC7786Attributes.l1ToL2TransactionParams.selector,
            IERC7786Attributes.factoryDeps.selector
        ];
    }
}
