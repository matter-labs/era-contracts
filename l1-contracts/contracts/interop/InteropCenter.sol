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
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, InteropCallStarter, InteropCallStarterInternal} from "../common/Messaging.sol";
import {MsgValueMismatch, Unauthorized} from "../common/L1ContractErrors.sol";
import {NotInGatewayMode} from "../bridgehub/L1BridgehubErrors.sol";

import {IAssetTracker} from "../bridge/asset-tracker/IAssetTracker.sol";
import {AttributeAlreadySet, AttributeNotForCall, AttributeNotForBundle} from "./InteropErrors.sol";

import {IERC7786GatewaySource} from "./IERC7786.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
/// @title InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the primary entry point for L1<->L2 communication, facilitating interactions between end user and bridges.
contract InteropCenter is IInteropCenter, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @notice The bridgehub, responsible for registering chains.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice The asset ID of ETH on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice All of the ETH and ERC20 tokens are held by NativeVaultToken managed by this AssetRouter.
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
        if (L1_CHAIN_ID != block.chainid) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2NotToL1(uint256 _destinationChainId) {
        if (L1_CHAIN_ID == block.chainid || _destinationChainId == L1_CHAIN_ID) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlySettlementLayerRelayedSender() {
        if (msg.sender != SETTLEMENT_LAYER_RELAY_SENDER) {
            revert Unauthorized(msg.sender);
        }
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

    /// @notice To set the addresses of some of the ecosystem contracts, only accessible to owner.
    ///         Not done in initialize, as the order of deployment is InteropCenter, other contracts, and then we call this.
    /// @param _assetRouter  Address of the AssetRouter component.
    /// @param _assetTracker  Address of the AssetTracker component on L1.
    function setAddresses(address _assetRouter, address _assetTracker) external onlyOwner {
        assetRouter = _assetRouter;
        assetTracker = IAssetTracker(_assetTracker);
    }

    /*//////////////////////////////////////////////////////////////
                        Bundle interface
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds a single InteropCall to a bundle at a given index.
    /// @param _interopBundle Bundle in-memory to update.
    /// @param _interopCallStarter Structure containing call parameters.
    /// @param _sender Originating address.
    /// @param _index Slot within the bundle to populate.
    function _addCallToBundle(
        InteropBundle memory _interopBundle,
        InteropCallStarter memory _interopCallStarter,
        uint256 _interopCallValue,
        address _sender,
        uint256 _index
    ) internal pure {
        // Form an InteropCall struct from given parameters.
        InteropCall memory interopCall = InteropCall({
            shadowAccount: false,
            to: _interopCallStarter.nextContract,
            data: _interopCallStarter.data,
            value: _interopCallValue,
            from: _sender
        });

        // Put it into a given InteropBundle at the specified index.
        _interopBundle.calls[_index] = interopCall;
    }

    /// @notice Finalizes, serializes, and sends a message corresponding to the bundle via the L2 to L1 messenger.
    /// @param _bundle InteropBundle struct corresponding to the bundle that is being sent.
    /// @param _bundleCallsTotalValue Total base token value for all calls.
    /// @param _executionAddress Address permitted to execute on remote chain.
    /// @param _receivedMsgValue ETH value sent with this L1->L2 call.
    /// @return interopBundleHash keccak256 hash of the encoded bundle.
    function _finalizeAndSendBundle(
        InteropBundle memory _bundle,
        uint256 _bundleCallsTotalValue,
        address _executionAddress,
        uint256 _receivedMsgValue
    ) internal returns (bytes32 interopBundleHash) {
        // Ensure that tokens required for bundle execution were received.
        _ensureCorrectTotalValue(_bundle.destinationChainId, _bundleCallsTotalValue, _receivedMsgValue);

        // Set the execution address of the bundle. It denotes the address who's able to call executeBundle on destination chain
        // to finalize this bundle. If it's not set (address(0)), then everyone is able to do so.
        _bundle.executionAddress = _executionAddress;

        bytes memory interopBundleBytes = abi.encode(_bundle);
        // TODO use canonicalTxHash for linking it to the trigger, instead of interopBundleHash
        // ! VG to KL. before merging pls resolve: why canonicalTxHash? That call returns hash of the message, no? Looks weird on the first glance
        // ! Send the message corresponding to the relevant InteropBundle to L1.
        bytes32 canonicalTxHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            bytes.concat(BUNDLE_IDENTIFIER, interopBundleBytes)
        );
        interopBundleHash = keccak256(interopBundleBytes);

        // Emit event stating that the bundle was sent out successfully.
        emit InteropBundleSent(canonicalTxHash, interopBundleHash, _bundle);
    }

    /// @notice Ensures the received base token value matches expected for the destination chain.
    /// @param _destinationChainId Destination chain ID.
    /// @param _totalValue Sum of requested interop call values.
    /// @param _receivedMsgValue Base token value attached to the transaction.
    function _ensureCorrectTotalValue(
        uint256 _destinationChainId,
        uint256 _totalValue,
        uint256 _receivedMsgValue
    ) internal {
        bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
        if (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) {
            // kl todo until we sort out chain registration on L2s we assume the same base token.
            // ! VG to KL. please resolve before merging: meaning we assume that base token is ETH on both?
            // ! didn't we figure out chain registration on L2s already? This whole if (L159-L170) looks weird to me, pls verify it yourself one more time.
            if (_receivedMsgValue != _totalValue) {
                revert MsgValueMismatch(_totalValue, _receivedMsgValue);
            }
        } else {
            if (_receivedMsgValue != 0) {
                revert MsgValueMismatch(0, _receivedMsgValue);
            }
        }

        // We burn the value that is passed along the bundle here, on source chain.
        // slither-disable-next-line arbitrary-send-eth
        if (tokenAssetId == BRIDGE_HUB.baseTokenAssetId(block.chainid)) {
            L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue{value: _totalValue}();
        } else {
            IL2AssetRouter(assetRouter).bridgehubDepositBaseToken(
                _destinationChainId,
                tokenAssetId,
                msg.sender,
                _totalValue
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EOA helpers
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
    ) public payable onlyL2NotToL1(_destinationChainId) returns (bytes32 bundleHash) {
        ERC7786Attributes memory attributes = _parseAttributes(
            _attributes,
            AttributeParsingOption.CallAndBundleAttributes
        );
        // Form an InteropBundle with given parameters.
        InteropBundle memory bundle = InteropBundle({
            destinationChainId: _destinationChainId,
            interopBundleSalt: keccak256(abi.encodePacked(msg.sender, bytes32(interopBundleNonce[msg.sender]))),
            calls: new InteropCall[](1),
            executionAddress: attributes.executionAddress,
            unbundlerAddress: attributes.unbundlerAddress
        });

        // Update interopBundleNonce for msg.sender
        ++interopBundleNonce[msg.sender];

        _addCallToBundle({
            _interopBundle: bundle,
            _interopCallStarter: InteropCallStarter({
                nextContract: _destinationAddress,
                data: _data,
                attributes: new bytes[](0)
            }),
            _interopCallValue: attributes.interopCallValue,
            _sender: msg.sender,
            _index: 0
        });

        // Send the bundle.
        bundleHash = _finalizeAndSendBundle({
            _bundle: bundle,
            _bundleCallsTotalValue: attributes.interopCallValue,
            _executionAddress: attributes.executionAddress,
            _receivedMsgValue: msg.value
        });
    }

    /// @notice Sends an interop bundle.
    ///         Same as above, but more than one call can be given, and they are given in InteropCallStarter format.
    /// @param _destinationChainId Chain ID to send to.
    /// @param _callStarters Array of call descriptors.
    /// @param _attributes Attributes of the bundle.
    /// @return bundleHash Hash of the sent bundle.
    function sendBundle(
        uint256 _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _attributes
    ) public payable onlyL2NotToL1(_destinationChainId) returns (bytes32 bundleHash) {
        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](
            _callStarters.length
        );
        uint256 callStartersLength = _callStarters.length;
        for (uint256 i = 0; i < callStartersLength; ++i) {
            ERC7786Attributes memory callAttributes = _parseAttributes(
                _callStarters[i].attributes,
                AttributeParsingOption.OnlyCallAttributes
            );
            callStartersInternal[i] = InteropCallStarterInternal({
                nextContract: _callStarters[i].nextContract,
                data: _callStarters[i].data,
                requestedInteropCallValue: callAttributes.interopCallValue,
                directCall: callAttributes.directCall,
                indirectCallMessageValue: callAttributes.indirectCallMessageValue
            });
        }
        ERC7786Attributes memory bundleAttributes = _parseAttributes(
            _attributes,
            AttributeParsingOption.OnlyBundleAttributes
        );
        bundleHash = _sendBundle({
            _destinationChainId: _destinationChainId,
            _callStarters: callStartersInternal,
            _msgValue: msg.value,
            _executionAddress: bundleAttributes.executionAddress,
            _unbundlerAddress: bundleAttributes.unbundlerAddress,
            _sender: msg.sender
        });
    }

    /// @notice Parses an InteropCallStarter struct.
    /// @param _attributes Attributes of the call.
    /// @param _option Option for parsing attributes.
    function _parseAttributes(
        bytes[] calldata _attributes,
        AttributeParsingOption _option
    ) internal pure returns (ERC7786Attributes memory attributesStruct) {
        // default value is direct call
        attributesStruct.directCall = true;

        bytes4[4] memory ATTRIBUTE_SELECTORS = [
            IERC7786Attributes.interopCallValue.selector,
            IERC7786Attributes.indirectCall.selector,
            IERC7786Attributes.executionAddress.selector,
            IERC7786Attributes.unbundlerAddress.selector
        ];
        // we can only pass each attribute once.
        bool[] memory attributeUsed = new bool[](4);
        // we store the read values of the attributes in an array.
        uint256[] memory attributeValues = new uint256[](4);

        uint256 attributeValuesLength = _attributes.length;
        for (uint256 i = 0; i < attributeValuesLength; ++i) {
            bytes4 selector = bytes4(_attributes[i]);
            uint256 indexInSelectorsArray = 0;
            /// Finding the matching attribute selector.
            uint256 attributeSelectorsLength = ATTRIBUTE_SELECTORS.length;
            for (uint256 j = 0; j < attributeSelectorsLength; ++j) {
                if (selector == ATTRIBUTE_SELECTORS[j]) {
                    /// check if the attribute was already set.
                    require(!attributeUsed[j], AttributeAlreadySet(j));
                    attributeUsed[j] = true;
                    indexInSelectorsArray = j;
                    break;
                }
                // the selector does not match any of the known attributes.
                if (j == attributeSelectorsLength - 1) {
                    revert IERC7786GatewaySource.UnsupportedAttribute(selector);
                }
            }
            if (indexInSelectorsArray < 2) {
                require(_option != AttributeParsingOption.OnlyBundleAttributes, AttributeNotForBundle(selector));
                attributeValues[indexInSelectorsArray] = AttributesDecoder.decodeUint256(_attributes[i]);
            } else {
                require(_option != AttributeParsingOption.OnlyCallAttributes, AttributeNotForCall(selector));
                attributeValues[indexInSelectorsArray] = AttributesDecoder.decodeAddress(_attributes[i]);
            }
            if (indexInSelectorsArray == 1) {
                // we have to overwrite the boolean value manually.
                attributesStruct.directCall = false;
            }
        }
        attributesStruct.interopCallValue = attributeValues[0];
        attributesStruct.indirectCallMessageValue = attributeValues[1];
        attributesStruct.executionAddress = address(uint160(attributeValues[2]));
        attributesStruct.unbundlerAddress = address(uint160(attributeValues[3]));
    }

    /// @notice Constructs and sends an InteropBundle.
    /// @param _destinationChainId Chain ID to send to.
    /// @param _callStarters Array of InteropCallStarterInternal structs, corresponding the the calls in bundle.
    /// @param _msgValue Total base token value forwarded.
    /// @param _executionAddress Address allowed to execute on remote side.
    /// @param _unbundlerAddress Address allowed to unbundle calls.
    /// @param _sender Origin address.
    /// @return bundleHash Hash of the sent bundle.
    function _sendBundle(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        uint256 _msgValue,
        address _executionAddress,
        address _unbundlerAddress,
        address _sender
    ) internal returns (bytes32 bundleHash) {
        // This will calculate how much value does all of the calls use cumulatively.
        uint256 totalCallsValue;

        // Form an InteropBundle.
        InteropBundle memory bundle = InteropBundle({
            destinationChainId: _destinationChainId,
            interopBundleSalt: keccak256(abi.encodePacked(_sender, interopBundleNonce[_sender])),
            calls: new InteropCall[](_callStarters.length),
            executionAddress: _executionAddress,
            unbundlerAddress: _unbundlerAddress
        });

        // Update interopBundleNonce for the _sender
        ++interopBundleNonce[_sender];

        // Fill the formed InteropBundle with calls.
        uint256 callStartersLength = _callStarters.length;
        for (uint256 i = 0; i < callStartersLength; ++i) {
            InteropCallStarterInternal memory callStarter = _callStarters[i];
            InteropCallStarter memory actualCallStarter;
            if (!callStarter.directCall) {
                // slither-disable-next-line arbitrary-send-eth
                actualCallStarter = IL2AssetRouter(callStarter.nextContract).interopCenterInitiateBridge{
                    value: callStarter.indirectCallMessageValue
                }(_destinationChainId, _sender, callStarter.requestedInteropCallValue, callStarter.data);
            } else {
                actualCallStarter = InteropCallStarter({
                    nextContract: callStarter.nextContract,
                    data: callStarter.data,
                    attributes: new bytes[](0)
                });
            }
            _addCallToBundle({
                _interopBundle: bundle,
                _interopCallStarter: actualCallStarter,
                _interopCallValue: callStarter.requestedInteropCallValue,
                _sender: _sender,
                _index: i
            });
            totalCallsValue += callStarter.requestedInteropCallValue;
        }

        // Send the bundle.
        bundleHash = _finalizeAndSendBundle({
            _bundle: bundle,
            _bundleCallsTotalValue: totalCallsValue,
            _executionAddress: _executionAddress,
            _receivedMsgValue: _msgValue
        });
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

    // ! VG to KL: whenNotPaused not used. Delete, or intended to add somewhere?

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
