// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {Unauthorized, ZeroAddress} from "../common/L1ContractErrors.sol";
import {
    BUNDLE_IDENTIFIER,
    BundleAttributes,
    CallAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall,
    InteropCallStarter
} from "../common/Messaging.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {ChainNotSettlingOnThisChain} from "../bridge/L1BridgeContractErrors.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IInteropAttributeParser} from "./IInteropAttributeParser.sol";
import {IInteropCenter} from "./IInteropCenter.sol";
import {IL1InteropCenter} from "./IL1InteropCenter.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {
    DestinationChainNotAllowed,
    DestinationChainNotRegistered,
    InteropBundleSaltAlreadyUsed,
    InteropToSelfNotSupported,
    InteroperableAddressChainReferenceNotEmpty,
    InteroperableAddressNotEmpty,
    OneWayBundleAttributeNotSupported,
    OneWayBundleNotSingleCall,
    OneWayCallNotIndirect,
    OneWayCallNotToAssetRouter,
    OneWayCallValueNotZero
} from "./InteropErrors.sol";

/// @title L1InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Sends one-way interop bundles from an L1 to the chains that settle on it, as local messages of the
/// L1's message root. See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
/// @dev Deployed behind a proxy on L1. Sending never calls a chain's own contract, so the destination can be any
/// chain registered in the Bridgehub.
contract L1InteropCenter is IL1InteropCenter, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev The Bridgehub, which names the asset router, the message root and each chain's settlement layer.
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @dev The stateless parser of ERC-7786 attributes.
    IInteropAttributeParser public immutable ATTRIBUTE_PARSER;

    /// @inheritdoc IL1InteropCenter
    mapping(uint256 chainId => bool enabled) public destinationEnabled;

    /// @inheritdoc IL1InteropCenter
    mapping(address sender => mapping(bytes32 salt => bool used)) public isInteropBundleSaltUsed;

    /// @dev Contract is expected to be used as a proxy implementation.
    /// @param _bridgehub The Bridgehub.
    /// @param _attributeParser The attribute parser.
    constructor(IBridgehubBase _bridgehub, IInteropAttributeParser _attributeParser) reentrancyGuardInitializer {
        _disableInitializers();
        require(address(_bridgehub) != address(0), ZeroAddress());
        require(address(_attributeParser) != address(0), ZeroAddress());
        BRIDGE_HUB = _bridgehub;
        ATTRIBUTE_PARSER = _attributeParser;
    }

    /// @notice Initializes the contract behind its proxy.
    /// @param _owner The owner, which enables destinations and can pause sending.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /// @notice Pauses sending bundles.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes sending bundles.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IL1InteropCenter
    function setDestinationEnabled(uint256 _chainId, bool _enabled) external {
        if (msg.sender != owner()) {
            address zkChain = BRIDGE_HUB.getZKChain(_chainId);
            require(
                !_enabled && zkChain != address(0) && msg.sender == IGetters(zkChain).getAdmin(),
                Unauthorized(msg.sender)
            );
        }
        destinationEnabled[_chainId] = _enabled;
        emit DestinationEnabledSet(_chainId, _enabled);
    }

    /// @inheritdoc IL1InteropCenter
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external nonReentrant whenNotPaused returns (bytes32 bundleHash) {
        uint256 destinationChainId = _parseDestination(_destinationChainId);

        require(_callStarters.length == 1, OneWayBundleNotSingleCall(_callStarters.length));
        address assetRouter = address(BRIDGE_HUB.assetRouter());
        _checkCallStarter(_callStarters[0], assetRouter);

        InteropBundle memory bundle = _buildBundle({
            _destinationChainId: destinationChainId,
            _assetRouter: assetRouter,
            _data: _callStarters[0].data,
            _bundleAttributes: _useBundleAttributes(_bundleAttributes)
        });
        bundleHash = _dispatchBundle(bundle);
        _emitMessageSent(bundleHash, bundle, _callStarters[0]);
    }

    /// @dev Emits the ERC-7786 event of the bundle's only call.
    function _emitMessageSent(
        bytes32 _bundleHash,
        InteropBundle memory _bundle,
        InteropCallStarter calldata _callStarter
    ) internal {
        emit IERC7786GatewaySource.MessageSent({
            sendId: keccak256(abi.encodePacked(_bundleHash, uint256(0))),
            sender: InteroperableAddress.formatEvmV1(block.chainid, _bundle.calls[0].from),
            recipient: InteroperableAddress.formatEvmV1(_bundle.destinationChainId, _bundle.calls[0].to),
            payload: _callStarter.data,
            value: 0,
            attributes: _callStarter.callAttributes
        });
    }

    /// @dev Takes the asset through the asset router and forms the bundle around the call the router returns.
    function _buildBundle(
        uint256 _destinationChainId,
        address _assetRouter,
        bytes calldata _data,
        BundleAttributes memory _bundleAttributes
    ) internal returns (InteropBundle memory bundle) {
        InteropCallStarter memory actualCallStarter = IL1AssetRouter(_assetRouter).initiateIndirectCall(
            _destinationChainId,
            msg.sender,
            _data
        );
        // slither-disable-next-line unused-return
        (, address callRecipient) = InteroperableAddress.parseEvmV1(actualCallStarter.to);

        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: BRIDGE_HUB.baseTokenAssetId(_destinationChainId),
            // This contract's address is part of the salt, so a replaced interop center never repeats a bundle hash.
            interopBundleSalt: keccak256(abi.encodePacked(address(this), msg.sender, _bundleAttributes.salt)),
            calls: new InteropCall[](1),
            bundleAttributes: _bundleAttributes
        });
        bundle.calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: callRecipient,
            from: _assetRouter,
            value: 0,
            data: actualCallStarter.data
        });
    }

    /// @dev Sends the bundle as a local message of the message root.
    function _dispatchBundle(InteropBundle memory _bundle) internal returns (bytes32 bundleHash) {
        bytes memory encodedBundle = abi.encode(_bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(encodedBundle);
        bytes32 messageHash = keccak256(bytes.concat(BUNDLE_IDENTIFIER, encodedBundle));
        uint256 batchNumber = IL1MessageRoot(address(BRIDGE_HUB.messageRoot())).sendLocalMessage(messageHash);

        emit IInteropCenter.InteropBundleSent(messageHash, bundleHash, _bundle);
        emit OneWayBundleSent(bundleHash, _bundle.destinationChainId, batchNumber);
    }

    /// @dev The destination must be an enabled chain of this Bridgehub that settles here and takes deposits.
    function _parseDestination(bytes calldata _destinationChainId) internal view returns (uint256 destinationChainId) {
        address addressField;
        (destinationChainId, addressField) = InteroperableAddress.parseEvmV1Calldata(_destinationChainId);
        require(addressField == address(0), InteroperableAddressNotEmpty(_destinationChainId));
        require(destinationChainId != block.chainid, InteropToSelfNotSupported());
        address zkChain = BRIDGE_HUB.getZKChain(destinationChainId);
        require(zkChain != address(0), DestinationChainNotRegistered(destinationChainId));
        // `depositsPaused` covers a migration in progress and the window before one starts: a bundle mints like a
        // deposit, and the chain's balance may already be on its way to another settlement layer.
        require(
            BRIDGE_HUB.settlementLayer(destinationChainId) == block.chainid && !IMailbox(zkChain).depositsPaused(),
            ChainNotSettlingOnThisChain(destinationChainId)
        );
        require(destinationEnabled[destinationChainId], DestinationChainNotAllowed(destinationChainId));
    }

    /// @dev The only call of a bundle is an indirect call to this chain's asset router, without value.
    function _checkCallStarter(InteropCallStarter calldata _callStarter, address _assetRouter) internal view {
        // slither-disable-next-line unused-return
        (CallAttributes memory callAttributes, ) = ATTRIBUTE_PARSER.parseAttributes(
            _callStarter.callAttributes,
            IInteropCenter.AttributeParsingRestrictions.OnlyCallAttributes
        );
        require(callAttributes.indirectCall, OneWayCallNotIndirect());
        require(
            callAttributes.interopCallValue == 0 && callAttributes.indirectCallMessageValue == 0,
            OneWayCallValueNotZero(callAttributes.interopCallValue + callAttributes.indirectCallMessageValue)
        );
        (uint256 starterChainId, address starterTarget) = InteroperableAddress.parseEvmV1Calldata(_callStarter.to);
        // The bundle's destination is the only chain a call goes to.
        require(starterChainId == 0, InteroperableAddressChainReferenceNotEmpty(_callStarter.to));
        require(starterTarget == _assetRouter, OneWayCallNotToAssetRouter(starterTarget));
    }

    /// @dev Parses the bundle attributes and marks the sender's salt as used. Only the salt is accepted: a one-way
    /// bundle is executed by anyone and is never unbundled, sends from L1 pay no interop fee, and an atomic flow has
    /// no L1 leg.
    function _useBundleAttributes(
        bytes[] calldata _bundleAttributes
    ) internal returns (BundleAttributes memory bundleAttributes) {
        uint256 attributesLength = _bundleAttributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            bytes4 selector = bytes4(_bundleAttributes[i]);
            require(
                selector == IERC7786Attributes.interopBundleSalt.selector,
                OneWayBundleAttributeNotSupported(selector)
            );
        }
        // slither-disable-next-line unused-return
        (, bundleAttributes) = ATTRIBUTE_PARSER.parseAttributes(
            _bundleAttributes,
            IInteropCenter.AttributeParsingRestrictions.OnlyBundleAttributes
        );

        require(
            !isInteropBundleSaltUsed[msg.sender][bundleAttributes.salt],
            InteropBundleSaltAlreadyUsed(msg.sender, bundleAttributes.salt)
        );
        isInteropBundleSaltUsed[msg.sender][bundleAttributes.salt] = true;
    }
}
