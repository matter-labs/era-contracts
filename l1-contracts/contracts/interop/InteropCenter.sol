// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IL2AssetRouter} from "../bridge/asset-router/IL2AssetRouter.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IInteropCenter} from "./IInteropCenter.sol";

import {L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractAddresses.sol";

import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "../common/Config.sol";
import {BUNDLE_IDENTIFIER, BundleAttributes, CallAttributes, INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION, InteropBundle, InteropCall, InteropCallStarter, InteropCallStarterInternal} from "../common/Messaging.sol";
import {MsgValueMismatch, NotL1, NotL2ToL2, Unauthorized} from "../common/L1ContractErrors.sol";
import {NotInGatewayMode} from "../bridgehub/L1BridgehubErrors.sol";

import {BalanceChange, IL2AssetTracker} from "../bridge/asset-tracker/IL2AssetTracker.sol";
import {AttributeAlreadySet, AttributeViolatesRestriction, IndirectCallValueMismatch} from "./InteropErrors.sol";

import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {InteroperableAddress} from "@openzeppelin/contracts-master/utils/draft-InteroperableAddress.sol";
import {IL2CrossChainSender} from "../bridge/interfaces/IL2CrossChainSender.sol";

/// @title InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the primary entry point for communication between chains connected to the interop, facilitating interactions between end user and bridges.
contract InteropCenter is
    IInteropCenter,
    IERC7786GatewaySource,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    /// @notice The bridgehub, responsible for registering chains.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice The asset ID of ETH on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice All of the ETH and ERC20 tokens are held by NativeTokenVault managed by this AssetRouter.
    address public assetRouter;

    /// @notice AssetTracker component address on L1. On L2 the address is L2_ASSET_TRACKER_ADDR.
    ///         It adds one more layer of security on top of cross chain communication.
    ///         Refer to its documentation for more details.
    /// @dev This is not used but is required for discoverability.
    IL2AssetTracker public assetTracker;

    /// @notice This mapping stores a number of interop bundles sent by an individual sender.
    ///         It's being used to derive interopBundleSalt in InteropBundle struct, whose role
    ///         is to ensure that each bundle has a unique hash.
    mapping(address sender => uint256 numberOfBundlesSent) public interopBundleNonce;

    modifier onlyL1() {
        require(L1_CHAIN_ID == block.chainid, NotL1(L1_CHAIN_ID, block.chainid));
        _;
    }

    modifier onlyL2ToL2(uint256 _destinationChainId) {
        _ensureL2ToL2(_destinationChainId);
        _;
    }

    modifier onlySettlementLayerRelayedSender() {
        require(msg.sender == SETTLEMENT_LAYER_RELAY_SENDER, Unauthorized(msg.sender));
        _;
    }

    /// @notice To avoid parity hack
    constructor(IBridgehub _bridgehub, uint256 _l1ChainId, address _owner) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

        _transferOwnership(_owner);
    }

    /// @notice Used to initialize the contract
    ///         InteropCenter is deployed on L2 as a system contract without a proxy thus initialization is needed only on L1.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer onlyL1 {
        _transferOwnership(_owner);
    }

    /// @notice To set the addresses of some of the ecosystem contracts, only accessible to owner.
    ///         Not done in initialize, as the order of deployment is InteropCenter, other contracts, and then we call this.
    /// @param _assetRouter  Address of the AssetRouter component.
    /// @param _assetTracker  Address of the AssetTracker component on L1.
    function setAddresses(address _assetRouter, address _assetTracker) external onlyOwner {
        address oldAssetRouter = assetRouter;
        address oldAssetTracker = address(assetTracker);

        assetRouter = _assetRouter;
        assetTracker = IL2AssetTracker(_assetTracker);

        emit NewAssetRouter(oldAssetRouter, _assetRouter);
        emit NewAssetTracker(oldAssetTracker, _assetTracker);
    }

    /*//////////////////////////////////////////////////////////////
                    InteropCenter entry points
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends a single ERC-7786 message to another chain.
    /// @param recipient ERC-7930 address corresponding to the destination of a message. It must be corresponding to an EIP-155 chain.
    /// @param payload Payload to send.
    /// @param attributes Attributes of the call.
    /// @return sendId Hash of the sent bundle containing a single call.
    function sendMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable whenNotPaused returns (bytes32 sendId) {
        (uint256 recipientChainId, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(recipient);

        _ensureL2ToL2(recipientChainId);

        (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) = parseAttributes(
            attributes,
            AttributeParsingRestrictions.CallAndBundleAttributes
        );

        // If the unbundler was not set for a call, we set the unbundler to be equal to the original sender, so that it's
        // still possible to unbundle the bundle containing the call. If the original sender is the contract, it'll still
        // be able to unbundle the bundle either via direct call to `unbundleBundle`, or via `sendMessage` to `InteropHandler`,
        // with specific payload. Refer to `InteropHandler` for details.
        if (bundleAttributes.unbundlerAddress.length == 0) {
            bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
        }

        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](1);
        callStartersInternal[0] = InteropCallStarterInternal({
            to: recipientAddress,
            data: payload,
            callAttributes: callAttributes
        });

        // Prepare original attributes array for the single call
        bytes[][] memory originalCallAttributes = new bytes[][](1);
        originalCallAttributes[0] = attributes;

        bytes32 bundleHash = _sendBundle(
            recipientChainId,
            callStartersInternal,
            bundleAttributes,
            originalCallAttributes
        );

        // We return the sendId of the only message that was sent in the bundle above. We always send messages in bundles, even if there's only one message being sent.
        // Note, that bundleHash is unique for every bundle. Each sendId is determined as keccak256 of bundleHash where the message (call) is contained,
        // and the index of the call inside the bundle.
        sendId = keccak256(abi.encodePacked(bundleHash, uint256(0)));
    }

    /// @notice Sends an interop bundle.
    ///         Same as above, but more than one call can be given, and they are given in InteropCallStarter format.
    /// @param _destinationChainId Chain ID to send to.
    /// @param _callStarters Array of call descriptors.
    /// @param _bundleAttributes Attributes of the bundle.
    /// @return bundleHash Hash of the sent bundle.
    function sendBundle(
        uint256 _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable onlyL2ToL2(_destinationChainId) whenNotPaused returns (bytes32 bundleHash) {
        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](
            _callStarters.length
        );
        uint256 callStartersLength = _callStarters.length;

        // Prepare original attributes array for all calls
        bytes[][] memory originalCallAttributes = new bytes[][](callStartersLength);

        for (uint256 i = 0; i < callStartersLength; ++i) {
            // Store original attributes for MessageSent event emission
            originalCallAttributes[i] = _callStarters[i].callAttributes;

            // solhint-disable-next-line no-unused-vars
            (CallAttributes memory callAttributes, ) = parseAttributes(
                _callStarters[i].callAttributes,
                AttributeParsingRestrictions.OnlyCallAttributes
            );
            callStartersInternal[i] = InteropCallStarterInternal({
                to: _callStarters[i].to,
                data: _callStarters[i].data,
                callAttributes: callAttributes
            });
        }
        // solhint-disable-next-line no-unused-vars
        (, BundleAttributes memory bundleAttributes) = parseAttributes(
            _bundleAttributes,
            AttributeParsingRestrictions.OnlyBundleAttributes
        );

        // If the unbundler was not set for a bundle, we set the unbundler to be equal to the original sender, so
        // that it's still possible to unbundle the bundle. If the original sender is the contract, it'll still be
        // able to unbundle the bundle either via direct call to `unbundleBundle`, or via `sendMessage` to `InteropHandler`,
        // with specific payload. Refer to `InteropHandler` for details.
        if (bundleAttributes.unbundlerAddress.length == 0) {
            bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
        }

        bundleHash = _sendBundle({
            _destinationChainId: _destinationChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    function _ensureL2ToL2(uint256 _destinationChainId) internal view {
        require(
            L1_CHAIN_ID != block.chainid && _destinationChainId != L1_CHAIN_ID,
            NotL2ToL2(block.chainid, _destinationChainId)
        );
    }

    /// @notice Ensures the received base token value matches expected for the destination chain.
    /// @param _destinationChainId Destination chain ID.
    /// @param _totalValue Sum of requested interop call values.
    function _ensureCorrectTotalValue(uint256 _destinationChainId, uint256 _totalValue) internal {
        bytes32 destinationChainBaseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
        // We burn the value that is passed along the bundle here, on source chain.
        bytes32 thisChainBaseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(block.chainid);
        if (destinationChainBaseTokenAssetId == thisChainBaseTokenAssetId) {
            require(msg.value == _totalValue, MsgValueMismatch(_totalValue, msg.value));
            // slither-disable-next-line arbitrary-send-eth
            L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue{value: _totalValue}();
        } else {
            require(msg.value == 0, MsgValueMismatch(0, msg.value));
            IL2AssetRouter(assetRouter).bridgehubDepositBaseToken(
                _destinationChainId,
                destinationChainBaseTokenAssetId,
                msg.sender,
                _totalValue
            );
        }
    }

    /// @notice Constructs and sends an InteropBundle, that includes sending a message corresponding to the bundle via the L2 to L1 messenger.
    /// @param _destinationChainId Chain ID to send to.
    /// @param _callStarters Array of InteropCallStarterInternal structs, corresponding to the calls in bundle.
    /// @param _bundleAttributes Attributes of the bundle.
    /// @param _originalCallAttributes Original ERC-7786 attributes for each call to emit in MessageSent events.
    /// @return bundleHash Hash of the sent bundle.
    function _sendBundle(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        BundleAttributes memory _bundleAttributes,
        bytes[][] memory _originalCallAttributes
    ) internal returns (bytes32 bundleHash) {
        require(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() != L1_CHAIN_ID, NotInGatewayMode());

        // This will calculate how much value does all of the calls use cumulatively.
        uint256 totalCallsValue;

        // Form an InteropBundle.
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: _destinationChainId,
            interopBundleSalt: keccak256(abi.encodePacked(msg.sender, interopBundleNonce[msg.sender])),
            calls: new InteropCall[](_callStarters.length),
            bundleAttributes: _bundleAttributes
        });

        // Update interopBundleNonce for the msg.sender
        ++interopBundleNonce[msg.sender];

        // Fill the formed InteropBundle with calls.
        uint256 callStartersLength = _callStarters.length;
        for (uint256 i = 0; i < callStartersLength; ++i) {
            InteropCall memory interopCall = _processCallStarter(_callStarters[i], _destinationChainId, msg.sender);
            bundle.calls[i] = interopCall;
            totalCallsValue += _callStarters[i].callAttributes.interopCallValue;
            // For indirect calls, also account for the bridge message value that gets sent to the AssetRouter
            if (_callStarters[i].callAttributes.indirectCall) {
                totalCallsValue += _callStarters[i].callAttributes.indirectCallMessageValue;
            }
        }

        // Ensure that tokens required for bundle execution were received.
        _ensureCorrectTotalValue(bundle.destinationChainId, totalCallsValue);

        bytes memory interopBundleBytes = abi.encode(bundle);

        // Send the message corresponding to the relevant InteropBundle to L1.
        bytes32 msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            bytes.concat(BUNDLE_IDENTIFIER, interopBundleBytes)
        );

        bundleHash = InteropDataEncoding.encodeInteropBundleHash(block.chainid, interopBundleBytes);

        // Emit ERC-7786 MessageSent event for each call in the bundle
        for (uint256 i = 0; i < callStartersLength; ++i) {
            InteropCall memory currentCall = bundle.calls[i];
            emit MessageSent({
                sendId: keccak256(abi.encodePacked(bundleHash, i)),
                sender: InteroperableAddress.formatEvmV1(block.chainid, currentCall.from),
                recipient: InteroperableAddress.formatEvmV1(_destinationChainId, currentCall.to),
                payload: _callStarters[i].data,
                value: _callStarters[i].callAttributes.interopCallValue,
                attributes: _originalCallAttributes[i]
            });
        }

        // Emit event stating that the bundle was sent out successfully.
        emit InteropBundleSent(msgHash, bundleHash, bundle);
    }

    function _processCallStarter(
        InteropCallStarterInternal memory _callStarter,
        uint256 _destinationChainId,
        address _sender
    ) internal returns (InteropCall memory interopCall) {
        if (_callStarter.callAttributes.indirectCall) {
            // slither-disable-next-line arbitrary-send-eth
            InteropCallStarter memory actualCallStarter = IL2CrossChainSender(_callStarter.to).initiateIndirectCall{
                value: _callStarter.callAttributes.indirectCallMessageValue
            }(_destinationChainId, _sender, _callStarter.callAttributes.interopCallValue, _callStarter.data);
            // solhint-disable-next-line no-unused-vars
            // slither-disable-next-line unused-return
            (CallAttributes memory indirectCallAttributes, ) = this.parseAttributes(
                actualCallStarter.callAttributes,
                AttributeParsingRestrictions.OnlyInteropCallValue
            );
            require(
                _callStarter.callAttributes.interopCallValue == indirectCallAttributes.interopCallValue,
                IndirectCallValueMismatch(
                    _callStarter.callAttributes.interopCallValue,
                    indirectCallAttributes.interopCallValue
                )
            );
            interopCall = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: actualCallStarter.to,
                data: actualCallStarter.data,
                value: _callStarter.callAttributes.interopCallValue,
                from: _callStarter.to
            });
        } else {
            interopCall = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: _callStarter.to,
                data: _callStarter.data,
                value: _callStarter.callAttributes.interopCallValue,
                from: _sender
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GW function
    //////////////////////////////////////////////////////////////*/

    /// @notice Forwards a transaction from the gateway to a chain mailbox (from L1).
    /// @param _chainId Target chain ID.
    /// @param _canonicalTxHash Canonical L1 transaction hash.
    /// @param _expirationTimestamp Expiration for gateway replay protection.
    /// @param _balanceChange Balance change for the transaction.
    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        BalanceChange memory _balanceChange
    ) external override onlySettlementLayerRelayedSender {
        if (L1_CHAIN_ID == block.chainid) {
            revert NotInGatewayMode();
        }
        _balanceChange.baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
        IL2AssetTracker(L2_ASSET_TRACKER_ADDR).handleChainBalanceIncreaseOnGateway({
            _chainId: _chainId,
            _canonicalTxHash: _canonicalTxHash,
            _balanceChange: _balanceChange
        });

        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        IZKChain(zkChain).bridgehubRequestL2TransactionOnGateway(_canonicalTxHash, _expirationTimestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC 7786
    //////////////////////////////////////////////////////////////*/

    /// @notice Parses the attributes of the call or bundle.
    /// @param _attributes ERC-7786 Attributes of the call or bundle.
    /// @param _restriction Restriction for parsing attributes.
    function parseAttributes(
        bytes[] calldata _attributes,
        AttributeParsingRestrictions _restriction
    ) public pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) {
        // Default value is direct call.
        callAttributes.indirectCall = false;

        bytes4[4] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
        // We can only pass each attribute once.
        bool[] memory attributeUsed = new bool[](ATTRIBUTE_SELECTORS.length);

        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            bytes4 selector = bytes4(_attributes[i]);

            if (selector == IERC7786Attributes.interopCallValue.selector) {
                require(!attributeUsed[0], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyInteropCallValue ||
                        _restriction == AttributeParsingRestrictions.OnlyCallAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[0] = true;
                callAttributes.interopCallValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (selector == IERC7786Attributes.indirectCall.selector) {
                require(!attributeUsed[1], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyCallAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[1] = true;
                callAttributes.indirectCall = true;
                callAttributes.indirectCallMessageValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (selector == IERC7786Attributes.executionAddress.selector) {
                require(!attributeUsed[2], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[2] = true;
                bundleAttributes.executionAddress = AttributesDecoder.decodeInteroperableAddress(_attributes[i]);
            } else if (selector == IERC7786Attributes.unbundlerAddress.selector) {
                require(!attributeUsed[3], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[3] = true;
                bundleAttributes.unbundlerAddress = AttributesDecoder.decodeInteroperableAddress(_attributes[i]);
            } else {
                revert IERC7786GatewaySource.UnsupportedAttribute(selector);
            }
        }
    }

    /// @notice Checks if the attribute selector is supported by the InteropCenter.
    /// @param _attributeSelector The attribute selector to check.
    /// @return True if the attribute selector is supported, false otherwise.
    function supportsAttribute(bytes4 _attributeSelector) external pure returns (bool) {
        bytes4[4] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
        uint256 attributeSelectorsLength = ATTRIBUTE_SELECTORS.length;
        for (uint256 i = 0; i < attributeSelectorsLength; ++i) {
            if (_attributeSelector == ATTRIBUTE_SELECTORS[i]) {
                return true;
            }
        }
        return false;
    }

    /// @notice Returns the attribute selectors supported by the InteropCenter.
    /// @return The attribute selectors supported by the InteropCenter.
    function _getERC7786AttributeSelectors() internal pure returns (bytes4[4] memory) {
        return [
            IERC7786Attributes.interopCallValue.selector,
            IERC7786Attributes.indirectCall.selector,
            IERC7786Attributes.executionAddress.selector,
            IERC7786Attributes.unbundlerAddress.selector
        ];
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
