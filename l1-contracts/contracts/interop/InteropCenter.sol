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
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, InteropCallStarter, InteropCallStarterInternal, CallAttributes, BundleAttributes, INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION} from "../common/Messaging.sol";
import {MsgValueMismatch, Unauthorized, NotL1, NotL2ToL2} from "../common/L1ContractErrors.sol";
import {NotInGatewayMode} from "../bridgehub/L1BridgehubErrors.sol";

import {IAssetTracker} from "../bridge/asset-tracker/IAssetTracker.sol";
import {AttributeAlreadySet, AttributeNotForCall, AttributeNotForBundle, IndirectCallValueMismatch, AttributeNotForInteropCallValue} from "./InteropErrors.sol";

import {IERC7786GatewaySource} from "./IERC7786.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";

/// @title InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the primary entry point for communication between chains connected to the interop, facilitating interactions between end user and bridges.
contract InteropCenter is IInteropCenter, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
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
    IAssetTracker public assetTracker;

    /// @notice This mapping stores a number of interop bundles sent by an individual sender.
    ///         It's being used to derive interopBundleSalt in InteropBundle struct, whose role
    ///         is to ensure that each bundle has a unique hash.
    mapping(address sender => uint256 numberOfBundlesSent) public interopBundleNonce;

    modifier onlyL1() {
        require(L1_CHAIN_ID == block.chainid, NotL1(L1_CHAIN_ID, block.chainid));
        _;
    }

    modifier onlyL2ToL2(uint256 _destinationChainId) {
        require(
            L1_CHAIN_ID != block.chainid && _destinationChainId != L1_CHAIN_ID,
            NotL2ToL2(block.chainid, _destinationChainId)
        );
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
    ///         This contract is also deployed on L2 as a system contract.
    ///         On the L2 owner and its related functions will not be used.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer onlyL1 {
        _transferOwnership(_owner);
    }

    /// @notice Used to set the address of the AssetRouter component. Only accessible to the owner.
    ///         Not done in initialize, as InteropCenter is deployed before AssetRouter, and then we call this.
    /// @param _assetRouter  Address of the AssetRouter component.
    function setAssetRouterAddress(address _assetRouter) external onlyOwner {
        assetRouter = _assetRouter;
        emit AssetRouterSet(_assetRouter);
    }

    /// @notice Used to set the address of the AssetTracker component. Only accessible to the owner.
    ///         Not done in initialize, as InteropCenter is deployed before AssetTracker, and then we call this.
    /// @param _assetTracker  Address of the AssetTracker component on L1.
    function setAssetTrackerAddress(address _assetTracker) external onlyOwner {
        assetTracker = IAssetTracker(_assetTracker);
        emit AssetTrackerSet(_assetTracker);
    }

    /*//////////////////////////////////////////////////////////////
                    InteropCenter entry points
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends a single call to another chain.
    /// @param _destinationChainId Chain ID to send to.
    /// @param _destinationAddress Address on remote chain.
    /// @param _data Calldata payload to send.
    /// @param _attributes Attributes of the call.
    /// @return bundleHash Hash of the sent bundle containing a single call.
    function sendCall(
        uint256 _destinationChainId,
        address _destinationAddress,
        bytes calldata _data,
        bytes[] calldata _attributes
    ) external payable onlyL2ToL2(_destinationChainId) whenNotPaused returns (bytes32 bundleHash) {
        (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) = parseAttributes(
            _attributes,
            AttributeParsingRestrictions.CallAndBundleAttributes
        );

        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](1);
        callStartersInternal[0] = InteropCallStarterInternal({
            to: _destinationAddress,
            data: _data,
            callAttributes: callAttributes
        });

        bundleHash = _sendBundle(_destinationChainId, callStartersInternal, bundleAttributes);
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
        for (uint256 i = 0; i < callStartersLength; ++i) {
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
        bundleHash = _sendBundle({
            _destinationChainId: _destinationChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalizes, serializes, and sends a message corresponding to the bundle via the L2 to L1 messenger.
    /// @param _bundle InteropBundle struct corresponding to the bundle that is being sent.
    /// @param _bundleCallsTotalValue Total base token value for all calls.
    /// @return interopBundleHash keccak256 hash of the encoded bundle.
    function _finalizeAndSendBundle(
        InteropBundle memory _bundle,
        uint256 _bundleCallsTotalValue
    ) internal returns (bytes32 interopBundleHash) {
        // Ensure that tokens required for bundle execution were received.
        _ensureCorrectTotalValue(_bundle.destinationChainId, _bundleCallsTotalValue);

        bytes memory interopBundleBytes = abi.encode(_bundle);

        // Send the message corresponding to the relevant InteropBundle to L1.
        bytes32 msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            bytes.concat(BUNDLE_IDENTIFIER, interopBundleBytes)
        );
        interopBundleHash = InteropDataEncoding.encodeInteropBundleHash(block.chainid, interopBundleBytes);

        // Emit event stating that the bundle was sent out successfully.
        emit InteropBundleSent(msgHash, interopBundleHash, _bundle);
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

    /// @notice Constructs and sends an InteropBundle.
    /// @param _destinationChainId Chain ID to send to.
    /// @param _callStarters Array of InteropCallStarterInternal structs, corresponding to the calls in bundle.
    /// @param _bundleAttributes Attributes of the bundle.
    /// @return bundleHash Hash of the sent bundle.
    function _sendBundle(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        BundleAttributes memory _bundleAttributes
    ) internal returns (bytes32 bundleHash) {
        // This will calculate how much value does all of the calls use cumulatively.
        uint256 totalCallsValue;

        // Form an InteropBundle.
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
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
        }

        // Send the bundle.
        bundleHash = _finalizeAndSendBundle({_bundle: bundle, _bundleCallsTotalValue: totalCallsValue});
    }

    function _processCallStarter(
        InteropCallStarterInternal memory _callStarter,
        uint256 _destinationChainId,
        address _sender
    ) internal returns (InteropCall memory interopCall) {
        if (_callStarter.callAttributes.directCall) {
            interopCall = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: _callStarter.to,
                data: _callStarter.data,
                value: _callStarter.callAttributes.interopCallValue,
                from: _sender
            });
        } else {
            // slither-disable-next-line arbitrary-send-eth
            InteropCallStarter memory actualCallStarter = IL2AssetRouter(_callStarter.to).interopCenterInitiateBridge{
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
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GW function
    //////////////////////////////////////////////////////////////*/

    /// @notice Forwards a transaction from the gateway to a chain mailbox (from L1).
    /// @param _chainId Target chain ID.
    /// @param _canonicalTxHash Canonical L1 transaction hash.
    /// @param _expirationTimestamp Expiration for gateway replay protection.
    /// @param _baseTokenAmount Amount of base token moved.
    /// @param _assetId Asset identifier for non-base tokens.
    /// @param _amount Amount of non-base asset moved.
    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        uint256 _baseTokenAmount,
        bytes32 _assetId,
        uint256 _amount
    ) external override onlySettlementLayerRelayedSender {
        require(L1_CHAIN_ID != block.chainid, NotInGatewayMode());
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
                            ERC 7786
    //////////////////////////////////////////////////////////////*/

    /// @notice Parses the attributes of the call or bundle.
    /// @param _attributes EIP-7786 Attributes of the call or bundle.
    /// @param _restriction Restriction for parsing attributes.
    function parseAttributes(
        bytes[] calldata _attributes,
        AttributeParsingRestrictions _restriction
    ) public pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) {
        // Default value is direct call.
        callAttributes.directCall = true;

        bytes4[4] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
        // We can only pass each attribute once.
        bool[] memory attributeUsed = new bool[](4);

        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            bytes4 selector = bytes4(_attributes[i]);
            /// Finding the matching attribute selector.
            uint256 attributeSelectorsLength = ATTRIBUTE_SELECTORS.length;
            uint256 indexInSelectorsArray = attributeSelectorsLength;
            for (uint256 j = 0; j < attributeSelectorsLength; ++j) {
                if (selector == ATTRIBUTE_SELECTORS[j]) {
                    /// check if the attribute was already set.
                    require(!attributeUsed[j], AttributeAlreadySet(j));
                    attributeUsed[j] = true;
                    indexInSelectorsArray = j;
                    break;
                }
            }
            // Revert if the selector does not match any of the known attributes.
            require(
                indexInSelectorsArray != attributeSelectorsLength,
                IERC7786GatewaySource.UnsupportedAttribute(selector)
            );
            // Checking whether selectors satisfy the restrictions.
            if (_restriction == AttributeParsingRestrictions.OnlyInteropCallValue) {
                require(indexInSelectorsArray == 0, AttributeNotForInteropCallValue(selector));
            }
            if (indexInSelectorsArray < 2) {
                require(
                    _restriction != AttributeParsingRestrictions.OnlyBundleAttributes,
                    AttributeNotForBundle(selector)
                );
            } else {
                require(
                    _restriction != AttributeParsingRestrictions.OnlyInteropCallValue,
                    AttributeNotForCall(selector)
                );
            }
            // setting the attributes
            if (indexInSelectorsArray == 0) {
                callAttributes.interopCallValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (indexInSelectorsArray == 1) {
                callAttributes.directCall = false;
                callAttributes.indirectCallMessageValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (indexInSelectorsArray == 2) {
                bundleAttributes.executionAddress = AttributesDecoder.decodeAddress(_attributes[i]);
            } else if (indexInSelectorsArray == 3) {
                bundleAttributes.unbundlerAddress = AttributesDecoder.decodeAddress(_attributes[i]);
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
