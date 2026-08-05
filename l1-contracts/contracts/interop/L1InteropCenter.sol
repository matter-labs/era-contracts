// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {ETH_TOKEN_ADDRESS, SUPPORTED_L1_INTEROP_ATTRIBUTES} from "../common/Config.sol";
import {ChainIdNotRegistered, ZeroAddress} from "../common/L1ContractErrors.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "../core/bridgehub/IBridgehubBase.sol";

import {AttributesDecoder} from "./AttributesDecoder.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IL1InteropCenter, L1MessageAttributes} from "./IL1InteropCenter.sol";
import {
    AttributeAlreadySet,
    FactoryDepsNotAllowedForIndirectCall,
    IndirectCallToAssetRouterMustUseBridgehub,
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
    using SafeERC20 for IERC20;

    /// @inheritdoc IL1InteropCenter
    IL1Bridgehub public immutable override BRIDGE_HUB;

    /// @dev The asset id of ETH on this chain, used to tell base-token value from base-token allowance.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    constructor(IL1Bridgehub _bridgehub) reentrancyGuardInitializer {
        require(address(_bridgehub) != address(0), ZeroAddress());
        BRIDGE_HUB = _bridgehub;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
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

        // The base token is pulled by the Bridgehub from its caller, i.e. from this contract.
        _forwardBaseTokenAllowance(destinationChainId, attributes.mintValue);

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

    /// @dev Relays a direct call, mapping the message onto the Bridgehub's direct request.
    function _relayDirectRequest(
        uint256 _destinationChainId,
        address _l2Contract,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash) {
        canonicalTxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(
            L2TransactionRequestDirect({
                chainId: _destinationChainId,
                mintValue: _attributes.mintValue,
                l2Contract: _l2Contract,
                l2Value: _attributes.interopCallValue,
                l2Calldata: _payload,
                l2GasLimit: _attributes.l2GasLimit,
                l2GasPerPubdataByteLimit: _attributes.l2GasPerPubdataByteLimit,
                factoryDeps: _attributes.factoryDeps,
                refundRecipient: _resolvedRefundRecipient(_attributes.refundRecipient)
            })
        );
    }

    /// @dev Relays an indirect call, mapping the message onto the Bridgehub's two-bridges request.
    /// @dev The cross-chain sender is called by the Bridgehub with this contract as the original caller, so it
    /// attributes the deposit to this contract instead of the message sender. Deposits through the asset router
    /// are therefore rejected: they must be initiated on the Bridgehub, so that the depositor stays the one who
    /// can recover a failed deposit. See {protocol-docs/l1-interop-center.md#indirect-calls}.
    function _relayIndirectRequest(
        uint256 _destinationChainId,
        address _crossChainSender,
        bytes calldata _payload,
        L1MessageAttributes memory _attributes
    ) private returns (bytes32 canonicalTxHash) {
        require(_attributes.factoryDeps.length == 0, FactoryDepsNotAllowedForIndirectCall());
        require(
            _crossChainSender != address(BRIDGE_HUB.assetRouter()),
            IndirectCallToAssetRouterMustUseBridgehub(_crossChainSender)
        );

        canonicalTxHash = BRIDGE_HUB.requestL2TransactionTwoBridges{value: msg.value}(
            L2TransactionRequestTwoBridgesOuter({
                chainId: _destinationChainId,
                mintValue: _attributes.mintValue,
                l2Value: _attributes.interopCallValue,
                l2GasLimit: _attributes.l2GasLimit,
                l2GasPerPubdataByteLimit: _attributes.l2GasPerPubdataByteLimit,
                refundRecipient: _resolvedRefundRecipient(_attributes.refundRecipient),
                secondBridgeAddress: _crossChainSender,
                secondBridgeValue: _attributes.indirectCallMessageValue,
                secondBridgeCalldata: _payload
            })
        );
    }

    /// @dev Resolves the refund recipient here rather than letting the Bridgehub default it: the Bridgehub would
    /// default it to its caller, which is this contract, and the refund would be stranded on its L2 alias.
    function _resolvedRefundRecipient(address _refundRecipient) private view returns (address) {
        return AddressAliasHelper.actualRefundRecipient(_refundRecipient, msg.sender);
    }

    /// @dev For a chain with an ERC20 base token the native token vault pulls `mintValue` from the Bridgehub's
    /// caller, i.e. from this contract, so the sender approves this contract and it forwards the allowance.
    /// The allowance is fully consumed by the request, which reverts as a whole if it is not.
    function _forwardBaseTokenAllowance(uint256 _chainId, uint256 _mintValue) private {
        if (_mintValue == 0) {
            return;
        }

        bytes32 baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
        if (baseTokenAssetId == ETH_TOKEN_ASSET_ID) {
            return;
        }

        INativeTokenVaultBase nativeTokenVault = IL1AssetRouter(address(BRIDGE_HUB.assetRouter())).nativeTokenVault();
        IERC20 baseToken = IERC20(nativeTokenVault.tokenAddress(baseTokenAssetId));
        baseToken.safeTransferFrom(msg.sender, address(this), _mintValue);
        baseToken.forceApprove(address(nativeTokenVault), _mintValue);
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
