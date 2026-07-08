// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IInteropCenter} from "./IInteropCenter.sol";

import {
    GW_ASSET_TRACKER,
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_HOLDER,
    L2_BRIDGEHUB,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT
} from "../common/l2-helpers/L2ContractInterfaces.sol";

import {SETTLEMENT_LAYER_RELAY_SENDER, SUPPORTED_INTEROP_ATTRIBUTES} from "../common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_ATOMIC_FLOW_MANAGER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {
    BUNDLE_IDENTIFIER,
    BalanceChange,
    BundleAttributes,
    CallAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall,
    InteropCallStarter,
    InteropCallStarterInternal
} from "../common/Messaging.sol";
import {AssetIdMismatch, MsgValueMismatch, NotL2ToL2, Unauthorized, ZeroAddress} from "../common/L1ContractErrors.sol";

import {
    AtomicBundleCallCarriesValue,
    AttributeAlreadySet,
    AttributeViolatesRestriction,
    DestinationChainNotRegistered,
    IndirectCallValueMismatch,
    InteropBundleSaltAlreadyUsed,
    InteroperableAddressChainReferenceNotEmpty,
    InteroperableAddressNotEmpty,
    FeeWithdrawalFailed,
    ZKTokenNotAvailable
} from "./InteropErrors.sol";

import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {IAtomicFlowManager} from "../atomic-interop/IAtomicFlowManager.sol";
import {ERC7930_V1_MIN_LENGTH} from "./InteropConstants.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {IL2CrossChainSender} from "../bridge/interfaces/IL2CrossChainSender.sol";
import {IAssetRouterShared} from "../bridge/asset-router/IAssetRouterShared.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";

/// @dev Default fixed fee for interop calls: 10 ZK tokens.
/// This is intentionally set sufficiently higher than the intended gateway settlement fee
/// (and so the intended dynamic fee), to incentivize users to use the dynamic fee path.
uint256 constant DEFAULT_ZK_INTEROP_FEE = 10e18;

/// @title InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the primary entry point for communication between chains connected to the interop, facilitating interactions between end user and bridges.
/// @dev as of V31 only deployed on the L2s, not on L1.
contract InteropCenter is
    IInteropCenter,
    IERC7786GatewaySource,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public L1_CHAIN_ID;

    /// @notice DEPRECATED. This mapping used to store the number of interop bundles sent by an individual sender,
    ///         which was used to derive the `interopBundleSalt` in the `InteropBundle` struct. The salt is now derived
    ///         from a user-provided value supplied via the `interopBundleSalt` ERC-7786 bundle attribute, so this nonce
    ///         is no longer read or written. The slot is retained to preserve the storage layout.
    mapping(address sender => uint256 numberOfBundlesSent) internal __DEPRECATED_interopBundleNonce;

    /// @notice Operator-set fee in base token per interop call (when useFixedFee=false).
    uint256 public interopProtocolFee;

    /// @notice Fixed fee amount in ZK tokens per interop call (when useFixedFee=true).
    /// @dev This is intentionally set to be the more expensive option compared to dynamic base token fees.
    ///      The fixed ZK fee provides Stage 1 protection - it allows users to pay fees independent of chain
    ///      operator settings, ensuring interop works even if the operator sets arbitrary dynamic fees.
    ///      Note, that it's not changeable throughout the code. It's not constant to make it possible to change
    ///      the exact value with protocol upgrade without redeploying contract.
    uint256 public ZK_INTEROP_FEE;

    /// @notice ZK token asset ID for resolving token address via native token vault.
    bytes32 public ZK_TOKEN_ASSET_ID;

    /// @notice Cached ZK token contract address (resolved from asset ID).
    IERC20 public zkToken;

    /// @notice Accumulated protocol fees (base token) per coinbase.
    /// @dev Coinbase addresses can claim their accumulated fees via claimProtocolFees().
    mapping(address coinbase => uint256 amount) public accumulatedProtocolFees;

    /// @notice Accumulated ZK fees per coinbase.
    /// @dev Coinbase addresses can claim their accumulated fees via claimZKFees().
    mapping(address coinbase => uint256 amount) public accumulatedZKFees;

    /// @notice Tracks which salts a given sender has already used for an interop bundle.
    /// @dev Used to guarantee that each bundle has a unique hash: the bundle hash commits to `interopBundleSalt`,
    ///      which is derived from `msg.sender` and the user-provided salt. Enforcing that each (sender, salt) pair is
    ///      used at most once therefore makes every emitted bundle hash unique. A sender must provide a distinct salt
    ///      for every bundle it sends, regardless of the bundle contents; reusing a salt makes `_sendBundle` revert with
    ///      `InteropBundleSaltAlreadyUsed`.
    mapping(address user => mapping(bytes32 salt => bool hasBeenUsed)) public isInteropBundleSaltUsed;

    modifier onlySettlementLayerRelayedSender() {
        require(msg.sender == SETTLEMENT_LAYER_RELAY_SENDER, Unauthorized(msg.sender));
        _;
    }

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        require(msg.sender == L2_COMPLEX_UPGRADER_ADDR, Unauthorized(msg.sender));
        _;
    }

    /// @dev Only allows calls from the bootloader.
    modifier onlyCallFromBootloader() {
        require(msg.sender == L2_BOOTLOADER_ADDRESS, Unauthorized(msg.sender));
        _;
    }

    /// @notice Returns the asset router address. Virtual to allow override in private interop.
    function _assetRouterAddr() internal view virtual returns (address) {
        return L2_ASSET_ROUTER_ADDR;
    }

    /// @notice Returns the native token vault. Virtual to allow override in private interop.
    function _nativeTokenVault() internal view virtual returns (IL2NativeTokenVault) {
        return IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT);
    }

    /// @inheritdoc IInteropCenter
    function getZKTokenAddress() public view returns (address) {
        // Check cached token first
        if (address(zkToken) != address(0)) {
            return address(zkToken);
        }

        // Try to resolve from asset ID
        return _nativeTokenVault().tokenAddress(ZK_TOKEN_ASSET_ID);
    }

    /// @notice Resolves ZK token address from asset ID with caching.
    /// @dev Uses native token vault to resolve asset ID to token address.
    /// @dev Reverts with ZKTokenNotAvailable() if ZK token hasn't been bridged to this chain yet.
    ///      This means useFixedFee=true is only available after ZK token is bridged to the source chain.
    /// @return The ZK token contract interface.
    function _getZKToken() internal returns (IERC20) {
        address tokenAddress = getZKTokenAddress();
        require(tokenAddress != address(0), ZKTokenNotAvailable());

        // Cache the resolved token if not already cached
        if (address(zkToken) == address(0)) {
            zkToken = IERC20(tokenAddress);
        }
        return IERC20(tokenAddress);
    }

    /// @inheritdoc IInteropCenter
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        bytes32 _zkTokenAssetId
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();

        // Note, that it is used to query and cache the ZK token address,
        // so in case someone tries to update it on L2, they should update the
        // zk token address as well.
        require(_zkTokenAssetId != bytes32(0), ZKTokenNotAvailable());
        ZK_TOKEN_ASSET_ID = _zkTokenAssetId;

        L1_CHAIN_ID = _l1ChainId;
        ZK_INTEROP_FEE = DEFAULT_ZK_INTEROP_FEE;
        if (owner() != _owner) {
            require(_owner != address(0), ZeroAddress());
            _transferOwnership(_owner);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    InteropCenter entry points
    //////////////////////////////////////////////////////////////*/
    /// @notice Sends a single ERC-7786 message to another chain.
    /// @param recipient ERC-7930 address corresponding to the destination of a message. It must be corresponding to an EIP-155 chain.
    /// @param payload Payload to send.
    function sendMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable whenNotPaused nonReentrant returns (bytes32 sendId) {
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

        // This single-call send path is never atomic; pass an empty AtomicSend (publishes to L1 as usual).
        bytes32 bundleHash = _sendBundle({
            _destinationChainId: recipientChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes,
            _atomicSend: AtomicSend({flowId: bytes32(0), lowNullifierIndex: 0, deadline: 0, isAtomic: false})
        });

        // We return the sendId of the only message that was sent in the bundle above. We always send messages in bundles, even if there's only one message being sent.
        // Note, that bundleHash is unique for every bundle. Each sendId is determined as keccak256 of bundleHash where the message (call) is contained,
        // and the index of the call inside the bundle.
        sendId = keccak256(abi.encodePacked(bundleHash, uint256(0)));
    }

    /// @inheritdoc IInteropCenter
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable whenNotPaused nonReentrant returns (bytes32 bundleHash) {
        // Validate that the destination chain ERC-7930 address has an empty address field.
        _ensureEmptyAddress(_destinationChainId);

        // Extract the actual chain ID from the ERC-7930 address
        // slither-disable-next-line unused-return
        (uint256 destinationChainId, ) = InteroperableAddress.parseEvmV1Calldata(_destinationChainId);

        // Ensure this is an L2 to L2 transaction
        _ensureL2ToL2(destinationChainId);
        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](
            _callStarters.length
        );
        uint256 callStartersLength = _callStarters.length;

        // Prepare original attributes array for all calls
        bytes[][] memory originalCallAttributes = new bytes[][](callStartersLength);

        for (uint256 i = 0; i < callStartersLength; ++i) {
            _ensureEmptyChainReference(_callStarters[i].to);

            // slither-disable-next-line unused-return
            (, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_callStarters[i].to);

            // Store original attributes for MessageSent event emission
            originalCallAttributes[i] = _callStarters[i].callAttributes;

            // solhint-disable-next-line no-unused-vars
            (CallAttributes memory callAttributes, ) = parseAttributes(
                _callStarters[i].callAttributes,
                AttributeParsingRestrictions.OnlyCallAttributes
            );
            callStartersInternal[i] = InteropCallStarterInternal({
                to: recipientAddress,
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

        AtomicSend memory atomicSend = _parseAtomicSend(_bundleAttributes);

        bundleHash = _sendBundle({
            _destinationChainId: destinationChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes,
            _atomicSend: atomicSend
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that the ERC-7930 address has an empty ChainReference field.
    /// @dev This function is used to ensure that CallStarters in sendBundle do not include ChainReference, as required
    ///      by our implementation. The ChainReference length is stored at byte offset 0x04 in the ERC-7930 format.
    /// @param _interoperableAddress The ERC-7930 address to verify.
    function _ensureEmptyChainReference(bytes calldata _interoperableAddress) internal pure {
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 chainReferenceLength = uint8(_interoperableAddress[0x04]);
        require(chainReferenceLength == 0, InteroperableAddressChainReferenceNotEmpty(_interoperableAddress));
    }

    /// @notice Verifies that the ERC-7930 address has an empty address field.
    /// @dev This function is used to ensure that the address does not contain an address field.
    ///      The address length is stored at byte offset (0x05 + chainReferenceLength) in the ERC-7930 format.
    /// @param _interoperableAddress The ERC-7930 address to verify.
    function _ensureEmptyAddress(bytes calldata _interoperableAddress) internal pure {
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 chainReferenceLength = uint8(_interoperableAddress[0x04]);
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH + chainReferenceLength,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 addressLength = uint8(_interoperableAddress[0x05 + chainReferenceLength]);
        require(addressLength == 0, InteroperableAddressNotEmpty(_interoperableAddress));
    }

    function _ensureL2ToL2(uint256 _destinationChainId) internal view {
        require(
            L1_CHAIN_ID != block.chainid && _destinationChainId != L1_CHAIN_ID,
            NotL2ToL2(block.chainid, _destinationChainId)
        );
    }

    /// @notice Ensures the received base token value matches expected for the destination chain
    /// @dev Handles fee collection based on useFixedFee flag. When useFixedFee is true, no base token fee is charged.
    /// @dev When useFixedFee is false, interopProtocolFee is charged in base tokens.
    /// @param _destinationChainId Destination chain ID.
    /// @param _totalBurnedCallsValue Sum of requested interop call values.
    /// @param _totalIndirectCallsValue Sum of requested indirect call values.
    /// @param _useFixedFee Whether fixed ZK fees were used (true) or base token fees required (false).
    /// @param _callCount Number of calls in the bundle for per-call fee calculation.
    function _ensureCorrectTotalValue(
        uint256 _destinationChainId,
        bytes32 _destinationBaseTokenAssetId,
        uint256 _totalBurnedCallsValue,
        uint256 _totalIndirectCallsValue,
        bool _useFixedFee,
        uint256 _callCount
    ) internal {
        bytes32 thisChainBaseTokenAssetId = _nativeTokenVault().BASE_TOKEN_ASSET_ID();

        // Calculate protocol fee - only charge base token fee if not using fixed ZK fees.
        // Fee is charged per-call.
        uint256 protocolFee = _useFixedFee ? 0 : interopProtocolFee * _callCount;

        // We burn the value that is passed along the bundle here, on source chain.
        if (_destinationBaseTokenAssetId == thisChainBaseTokenAssetId) {
            uint256 expectedValue = _totalBurnedCallsValue + _totalIndirectCallsValue + protocolFee;
            require(msg.value == expectedValue, MsgValueMismatch(expectedValue, msg.value));

            // Burn user value for interop calls.
            if (_totalBurnedCallsValue > 0) {
                // TODO(EVM-1395): unify same-base-token interop funding with the L2AssetRouter/L2NTV path
                // so InteropCenter does not need a dedicated BaseTokenHolder branch here.
                // Send tokens to BaseTokenHolder and notify L2AssetTracker via burnAndStartBridging
                L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: _totalBurnedCallsValue}(_destinationChainId);
            }
        } else {
            uint256 expectedValue = _totalIndirectCallsValue + protocolFee;
            require(msg.value == expectedValue, MsgValueMismatch(expectedValue, msg.value));

            // Handle cross-chain token deposit for different base tokens
            if (_totalBurnedCallsValue > 0) {
                IAssetRouterShared(_assetRouterAddr()).bridgehubDepositBaseToken(
                    _destinationChainId,
                    _destinationBaseTokenAssetId,
                    msg.sender,
                    _totalBurnedCallsValue
                );
            }
        }
        // Accumulate the fee for later withdrawal via claimProtocolFees().
        // This is handled to not allow malicious operator to fail sending bundles by providing faulty coinbase
        // and to avoid calls to any untrusted contracts.
        if (protocolFee > 0) {
            accumulatedProtocolFees[block.coinbase] += protocolFee;
            emit ProtocolFeesAccumulated(block.coinbase, protocolFee);
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
        bytes[][] memory _originalCallAttributes,
        AtomicSend memory _atomicSend
    ) internal returns (bytes32 bundleHash) {
        // Ensure the sender has not already used this salt. Since `interopBundleSalt` (and thus the bundle hash) is
        // derived from `msg.sender` and the user-provided salt, enforcing a unique salt per sender guarantees that
        // every emitted bundle has a unique hash.
        require(
            !isInteropBundleSaltUsed[msg.sender][_bundleAttributes.salt],
            InteropBundleSaltAlreadyUsed(msg.sender, _bundleAttributes.salt)
        );
        isInteropBundleSaltUsed[msg.sender][_bundleAttributes.salt] = true;

        // Form an InteropBundle.
        bytes32 destinationBaseTokenAssetId = _getDestinationBaseTokenAssetId(_destinationChainId);
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            // The salt is derived from the sender and a user-provided salt (from the `interopBundleSalt` bundle attribute).
            // Mixing in `msg.sender` ensures bundles from different senders can never collide, while the user-provided salt
            // lets the sender control uniqueness of their own bundles. A random user-provided salt additionally keeps the
            // resulting bundle hash unpredictable, preserving the bundle's privacy.
            interopBundleSalt: keccak256(abi.encodePacked(msg.sender, _bundleAttributes.salt)),
            calls: new InteropCall[](_callStarters.length),
            bundleAttributes: _bundleAttributes
        });

        // This will calculate how much value does all of the calls use cumulatively.
        uint256 totalBurnedCallsValue;
        uint256 totalIndirectCallsValue;

        // Fill the formed InteropBundle with calls.
        uint256 callStartersLength = _callStarters.length;
        for (uint256 i = 0; i < callStartersLength; ++i) {
            _validateCallStarterValue(_callStarters[i].callAttributes.interopCallValue);
            InteropCall memory interopCall = _processCallStarter(_callStarters[i], _destinationChainId, msg.sender);
            bundle.calls[i] = interopCall;
            totalBurnedCallsValue += _callStarters[i].callAttributes.interopCallValue;
            // For indirect calls, also account for the bridge message value that gets sent to the AssetRouter
            if (_callStarters[i].callAttributes.indirectCall) {
                totalIndirectCallsValue += _callStarters[i].callAttributes.indirectCallMessageValue;
            }
        }

        // If using fixed fees, collect ZK tokens per-call and accumulate for coinbase.
        // Coinbase can later claim via claimZKFees().
        // This is handled to not allow malicious operator to fail sending bundles by providing malicious coinbase.
        if (_bundleAttributes.useFixedFee) {
            uint256 totalZKFee = ZK_INTEROP_FEE * callStartersLength;
            _getZKToken().safeTransferFrom(msg.sender, address(this), totalZKFee);
            accumulatedZKFees[block.coinbase] += totalZKFee;
            emit FixedZKFeesAccumulated(msg.sender, block.coinbase, totalZKFee);
        }

        // Ensure that tokens required for bundle execution were received.
        _handleValueCollection({
            _destinationChainId: bundle.destinationChainId,
            _destinationBaseTokenAssetId: bundle.destinationBaseTokenAssetId,
            _totalBurnedCallsValue: totalBurnedCallsValue,
            _totalIndirectCallsValue: totalIndirectCallsValue,
            _useFixedFee: _bundleAttributes.useFixedFee,
            _callCount: callStartersLength
        });

        // Hash the bundle and dispatch it: an atomic bundle (one carrying the `atomicBundle` attribute)
        // is appended to the interop IMT via the AtomicFlowManager and is NOT published to L1; a normal
        // bundle is published to L1. The atomic send metadata travels out-of-band (`_atomicSend`), not
        // embedded in the bundle, so `bundleHash` does not depend on `flowId` (a circular dependency).
        bytes32 msgHash;
        (bundleHash, msgHash) = _dispatchBundle(bundle, _atomicSend);

        _emitMessageSent({
            _calls: bundle.calls,
            _destinationChainId: _destinationChainId,
            _bundleHash: bundleHash,
            _callStarters: _callStarters,
            _originalCallAttributes: _originalCallAttributes
        });

        // Emit event stating that the bundle was sent out successfully.
        emit InteropBundleSent(msgHash, bundleHash, bundle);
    }

    /// @notice Returns the base token asset ID for the destination chain. Override for pre-v31 chains.
    function _getDestinationBaseTokenAssetId(uint256 _destinationChainId) internal view virtual returns (bytes32) {
        bytes32 assetId = L2_BRIDGEHUB.baseTokenAssetId(_destinationChainId);
        require(assetId != bytes32(0), DestinationChainNotRegistered(_destinationChainId));
        return assetId;
    }

    /// @notice Validates a single call starter's interopCallValue. Any value is allowed.
    function _validateCallStarterValue(uint256 /* _interopCallValue */) internal pure {
        // No validation needed.
    }

    /// @notice Handles base-token value collection for the bundle.
    function _handleValueCollection(
        uint256 _destinationChainId,
        bytes32 _destinationBaseTokenAssetId,
        uint256 _totalBurnedCallsValue,
        uint256 _totalIndirectCallsValue,
        bool _useFixedFee,
        uint256 _callCount
    ) internal {
        // solhint-disable-next-line
        _ensureCorrectTotalValue(
            _destinationChainId,
            _destinationBaseTokenAssetId,
            _totalBurnedCallsValue,
            _totalIndirectCallsValue,
            _useFixedFee,
            _callCount
        );
    }

    /// @notice Sends the bundle message to L1. Override in private interop to send hash-only format.
    /// @return msgHash The hash returned by the L2→L1 messenger.
    function _sendBundleToL1(
        bytes memory _interopBundleBytes,
        uint256 /* _callCount */
    ) internal virtual returns (bytes32 msgHash) {
        msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(bytes.concat(BUNDLE_IDENTIFIER, _interopBundleBytes));
    }

    /// @notice Hashes the bundle and dispatches it. An atomic bundle (`_atomicSend.isAtomic`) has its
    /// commit value appended to the interop IMT via the {AtomicFlowManager} and is NOT published to L1
    /// — the burn already happened through the normal `initiateIndirectCall` path, and the destination
    /// executes it via {InteropHandler.executeAtomicBundle}. A normal bundle is published to L1 via
    /// {_sendBundleToL1}.
    /// @dev `_atomicSend` (flowId/deadline/lowNullifierIndex) is passed out-of-band and is intentionally
    /// NOT embedded in `_bundle`, so `bundleHash` is independent of `flowId`. This is required:
    /// `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))`
    /// must be computable off-chain before the send, which is impossible if a `bundleHash` (a flowId
    /// input) embedded `flowId`.
    function _dispatchBundle(
        InteropBundle memory _bundle,
        AtomicSend memory _atomicSend
    ) internal returns (bytes32 bundleHash, bytes32 msgHash) {
        bytes memory interopBundleBytes = abi.encode(_bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(block.chainid, interopBundleBytes);

        if (_atomicSend.isAtomic) {
            // Reject legs carrying irreversible native `value` before committing; timeout recovery is
            // otherwise best-effort (see {AtomicFlowManager._recoverBundle}).
            _validateAtomicBundle(_bundle);
            IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).append({
                _flowId: _atomicSend.flowId,
                _bundleHash: bundleHash,
                _deadline: _atomicSend.deadline,
                _lowNullifierIndex: _atomicSend.lowNullifierIndex
            });
        } else {
            msgHash = _sendBundleToL1(interopBundleBytes, _bundle.calls.length);
        }
    }

    /// @notice Rejects atomic-bundle calls that carry native base-token `value`. Such a leg is bridged via
    /// the base-token holder, which {IAtomicRecoverable.recoverAtomicCall} cannot reverse, so it would lock
    /// on timeout with no way to return the funds. Everything else is allowed: an atomic bundle may mix
    /// recoverable fund calls (asset-router deposits) with calls that move no funds (e.g. flipping a flag),
    /// and timeout recovery is best-effort (see {AtomicFlowManager._recoverBundle}). Refund safety for a
    /// fund-moving leg is therefore the flow author's responsibility; only native-`value` legs — which no
    /// one can reverse — are blocked here.
    /// @dev `pure`, since it inspects only the bundle's own calls. Every atomic send passes through
    /// {_dispatchBundle}, so this covers all atomic bundles regardless of entry path.
    function _validateAtomicBundle(InteropBundle memory _bundle) internal pure {
        uint256 callsLength = _bundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            if (_bundle.calls[i].value != 0) {
                revert AtomicBundleCallCarriesValue(i, _bundle.calls[i].value);
            }
        }
    }

    /// @notice Emits ERC-7786 MessageSent events for each call in a bundle.
    function _emitMessageSent(
        InteropCall[] memory _calls,
        uint256 _destinationChainId,
        bytes32 _bundleHash,
        InteropCallStarterInternal[] memory _callStarters,
        bytes[][] memory _originalCallAttributes
    ) internal {
        uint256 callsLength = _callStarters.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            InteropCall memory currentCall = _calls[i];
            emit MessageSent({
                sendId: keccak256(abi.encodePacked(_bundleHash, i)),
                sender: InteroperableAddress.formatEvmV1(block.chainid, currentCall.from),
                recipient: InteroperableAddress.formatEvmV1(_destinationChainId, currentCall.to),
                payload: _callStarters[i].data,
                value: _callStarters[i].callAttributes.interopCallValue,
                attributes: _originalCallAttributes[i]
            });
        }
    }

    function _processCallStarter(
        InteropCallStarterInternal memory _callStarter,
        uint256 _destinationChainId,
        address _sender
    ) internal returns (InteropCall memory interopCall) {
        // Use the already-parsed address from InteropCallStarterInternal
        address recipientAddress = _callStarter.to;

        if (_callStarter.callAttributes.indirectCall) {
            // InteropCenter supports generic indirect calls with both source-chain msg.value and destination-side
            // interopCallValue. Whether a particular indirect path supports non-zero interopCallValue is defined by
            // the concrete IL2CrossChainSender implementation (e.g. the current L2AssetRouter/NTV path does not).
            // slither-disable-next-line arbitrary-send-eth
            InteropCallStarter memory actualCallStarter = IL2CrossChainSender(recipientAddress).initiateIndirectCall{
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
            // Parse the returned 7930 address from actualCallStarter.to
            // slither-disable-next-line unused-return
            (, address actualCallRecipient) = InteroperableAddress.parseEvmV1(actualCallStarter.to);
            interopCall = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: actualCallRecipient,
                data: actualCallStarter.data,
                value: _callStarter.callAttributes.interopCallValue,
                from: recipientAddress
            });
        } else {
            interopCall = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: recipientAddress,
                data: _callStarter.data,
                value: _callStarter.callAttributes.interopCallValue,
                from: _sender
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GW function
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInteropCenter
    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        BalanceChange calldata _balanceChange
    ) external override onlySettlementLayerRelayedSender {
        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
        if (zkChain == address(0)) {
            revert DestinationChainNotRegistered(_chainId);
        }

        bytes32 baseTokenAssetId = L2_BRIDGEHUB.baseTokenAssetId(_chainId);
        if (_balanceChange.baseTokenAssetId != baseTokenAssetId) {
            revert AssetIdMismatch(baseTokenAssetId, _balanceChange.baseTokenAssetId);
        }
        GW_ASSET_TRACKER.handleChainBalanceIncreaseOnGateway({
            _chainId: _chainId,
            _canonicalTxHash: _canonicalTxHash,
            _balanceChange: _balanceChange
        });

        IZKChain(zkChain).bridgehubRequestL2TransactionOnGateway(_canonicalTxHash, _expirationTimestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC 7786
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInteropCenter
    function parseAttributes(
        bytes[] calldata _attributes,
        AttributeParsingRestrictions _restriction
    ) public pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) {
        // Default value is direct call.
        callAttributes.indirectCall = false;

        bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
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
                _validateOptionalInteroperableAddress(bundleAttributes.executionAddress);
            } else if (selector == IERC7786Attributes.unbundlerAddress.selector) {
                require(!attributeUsed[3], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[3] = true;
                bundleAttributes.unbundlerAddress = AttributesDecoder.decodeInteroperableAddress(_attributes[i]);
                _validateOptionalInteroperableAddress(bundleAttributes.unbundlerAddress);
            } else if (selector == IERC7786Attributes.useFixedFee.selector) {
                require(!attributeUsed[4], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[4] = true;

                // Decode the boolean parameter using AttributesDecoder
                bool useFixed = AttributesDecoder.decodeBool(_attributes[i]);
                bundleAttributes.useFixedFee = useFixed;
            } else if (selector == IERC7786Attributes.atomicBundle.selector) {
                require(!attributeUsed[5], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[5] = true;
                // The atomic send metadata (flowId/deadline/lowNullifierIndex) is parsed separately via
                // `_parseAtomicSend` and NOT stored in `BundleAttributes` — it must stay out of the
                // cross-chain bundle so `bundleHash` does not depend on `flowId` (a circular dependency).
                // Here we only validate it is a permitted, non-duplicate bundle attribute.
            } else if (selector == IERC7786Attributes.interopBundleSalt.selector) {
                require(!attributeUsed[6], AttributeAlreadySet(selector));
                require(
                    _restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                        _restriction == AttributeParsingRestrictions.CallAndBundleAttributes,
                    AttributeViolatesRestriction(selector, uint256(_restriction))
                );
                attributeUsed[6] = true;
                bundleAttributes.salt = AttributesDecoder.decodeBytes32(_attributes[i]);
            } else {
                revert IERC7786GatewaySource.UnsupportedAttribute(selector);
            }
        }
    }

    /// @notice Extracts the `atomicBundle` send metadata from the bundle attributes (already validated
    /// by `parseAttributes`). Returns `isAtomic = false` when the attribute is absent. Kept separate
    /// from `parseAttributes`/`BundleAttributes` so the metadata never enters the cross-chain bundle
    /// (which would make `bundleHash` depend on `flowId` — a circular dependency).
    function _parseAtomicSend(bytes[] calldata _attributes) internal pure returns (AtomicSend memory atomicSend) {
        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            if (bytes4(_attributes[i]) == IERC7786Attributes.atomicBundle.selector) {
                (atomicSend.flowId, atomicSend.deadline, atomicSend.lowNullifierIndex) = AttributesDecoder
                    .decodeAtomicBundle(_attributes[i]);
                atomicSend.isAtomic = true;
            }
        }
    }

    function _validateOptionalInteroperableAddress(bytes memory _interoperableAddress) internal pure {
        if (_interoperableAddress.length == 0) {
            return;
        }

        // slither-disable-next-line unused-return
        InteroperableAddress.parseEvmV1(_interoperableAddress);
    }

    /// @notice Checks if the attribute selector is supported by the InteropCenter.
    /// @param _attributeSelector The attribute selector to check.
    /// @return True if the attribute selector is supported, false otherwise.
    function supportsAttribute(bytes4 _attributeSelector) external pure override returns (bool) {
        bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
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
    function _getERC7786AttributeSelectors() internal pure returns (bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory) {
        return
            [
                IERC7786Attributes.interopCallValue.selector,
                IERC7786Attributes.indirectCall.selector,
                IERC7786Attributes.executionAddress.selector,
                IERC7786Attributes.unbundlerAddress.selector,
                IERC7786Attributes.useFixedFee.selector,
                IERC7786Attributes.atomicBundle.selector,
                IERC7786Attributes.interopBundleSalt.selector
            ];
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInteropCenter
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IInteropCenter
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            Fee Management
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInteropCenter
    function setInteropFee(uint256 _fee) external onlyCallFromBootloader {
        uint256 oldFee = interopProtocolFee;
        interopProtocolFee = _fee;
        emit InteropFeeUpdated(oldFee, _fee);
    }

    /// @inheritdoc IInteropCenter
    function claimProtocolFees(address _receiver) external nonReentrant {
        uint256 amount = accumulatedProtocolFees[msg.sender];
        if (amount == 0) {
            return;
        }

        accumulatedProtocolFees[msg.sender] = 0;

        // slither-disable-next-line arbitrary-send-eth
        (bool success, ) = _receiver.call{value: amount}("");
        require(success, FeeWithdrawalFailed());

        emit ProtocolFeesClaimed(msg.sender, _receiver, amount);
    }

    /// @inheritdoc IInteropCenter
    function claimZKFees(address _receiver) external nonReentrant {
        uint256 amount = accumulatedZKFees[msg.sender];
        if (amount == 0) {
            return;
        }

        accumulatedZKFees[msg.sender] = 0;
        _getZKToken().safeTransfer(_receiver, amount);

        emit ZKFeesClaimed(msg.sender, _receiver, amount);
    }
}
