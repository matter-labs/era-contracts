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
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_HOLDER,
    L2_BRIDGEHUB,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT
} from "../common/l2-helpers/L2ContractInterfaces.sol";

import {SETTLEMENT_LAYER_RELAY_SENDER, SUPPORTED_INTEROP_ATTRIBUTES, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {L2_BOOTLOADER_ADDRESS, L2_ATOMIC_FLOW_MANAGER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {
    BUNDLE_IDENTIFIER,
    BundleAttributes,
    CallAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall,
    InteropCallStarter,
    InteropCallStarterInternal
} from "../common/Messaging.sol";
import {MsgValueMismatch, NotL2ToL2, Unauthorized, ZeroAddress} from "../common/L1ContractErrors.sol";

import {
    AtomicBundleCallCarriesValue,
    AtomicBundleNotAllowedInSendMessage,
    AtomicBundleToL1NotSupported,
    AttributeAlreadySet,
    AttributeViolatesRestriction,
    CannotInitiateInteropOnL1,
    DestinationChainNotRegistered,
    DirectCallToL1NotSupported,
    IndirectCallValueMismatch,
    InteropBundleSaltAlreadyUsed,
    InteropCallToL1NotToAssetRouter,
    InteroperableAddressChainReferenceNotEmpty,
    InteroperableAddressNotEmpty,
    FeeWithdrawalFailed,
    InteropToSelfNotSupported,
    MultiCallToL1NotSupported,
    NonZeroValueToL1NotSupported,
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

/// @dev Default fixed ZK fee per interop call; intentionally above the intended dynamic fee to
/// incentivize the dynamic path. See {protocol-docs/interop.md} (fee model).
uint256 constant DEFAULT_ZK_INTEROP_FEE = 10e18;

/// @title InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Primary entry point for interop between chains: forms interop bundles and dispatches them
/// (L2->L1 message, or IMT commit for atomic bundles). Deployed on L2s only as of v31.
/// See {protocol-docs/interop.md}.
contract InteropCenter is
    IInteropCenter,
    IERC7786GatewaySource,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value
    /// always refers to the base-most L1.
    uint256 public L1_CHAIN_ID;

    /// @notice DEPRECATED. Formerly the per-sender bundle nonce the salt was derived from (now the
    ///         salt is user-provided); the slot is retained to preserve the storage layout.
    mapping(address sender => uint256 numberOfBundlesSent) internal __DEPRECATED_interopBundleNonce;

    /// @notice Operator-set fee in base token per interop call (when useFixedFee=false).
    uint256 public interopProtocolFee;

    /// @notice Fixed fee amount in ZK tokens per interop call (when useFixedFee=true). Provides Stage 1
    ///      protection; see {protocol-docs/interop.md} (fee model).
    /// @dev Not changeable at runtime; a storage variable (not a constant) only so a protocol upgrade
    ///      can change the value without redeploying.
    uint256 public ZK_INTEROP_FEE;

    /// @notice ZK token asset ID for resolving token address via native token vault.
    bytes32 public ZK_TOKEN_ASSET_ID;

    /// @notice Cached ZK token contract address (resolved from asset ID).
    IERC20 public zkToken;

    /// @notice Accumulated protocol fees (base token) per coinbase, claimable via claimProtocolFees().
    mapping(address coinbase => uint256 amount) public accumulatedProtocolFees;

    /// @notice Accumulated ZK fees per coinbase, claimable via claimZKFees().
    mapping(address coinbase => uint256 amount) public accumulatedZKFees;

    /// @notice Tracks which salts a sender has already used; a (sender, salt) pair may be used at most
    ///      once, which makes every emitted bundle hash unique. See {protocol-docs/interop.md}
    ///      (replay protection).
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
        if (address(zkToken) != address(0)) {
            return address(zkToken);
        }
        return _nativeTokenVault().tokenAddress(ZK_TOKEN_ASSET_ID);
    }

    /// @notice Resolves the ZK token address from its asset ID (via the NTV), caching the result.
    /// @dev Reverts with `ZKTokenNotAvailable` if the ZK token has not been bridged to this chain yet,
    ///      so useFixedFee=true only works after it is.
    /// @return The ZK token contract interface.
    function _getZKToken() internal returns (IERC20) {
        address tokenAddress = getZKTokenAddress();
        require(tokenAddress != address(0), ZKTokenNotAvailable());

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

        // Anyone updating this asset id later must also update the cached `zkToken` address.
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
    /// @notice Sends a single ERC-7786 message to another chain (wrapped into a single-call bundle).
    /// @param recipient ERC-7930 address of the message destination (must be an EIP-155 chain).
    /// @param payload Payload to send.
    /// @param attributes ERC-7786 attributes (call- and bundle-level are both accepted here).
    /// @return sendId `keccak256(bundleHash, 0)` — the ERC-7786 id of the single sent call.
    function sendMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable whenNotPaused nonReentrant returns (bytes32 sendId) {
        (uint256 recipientChainId, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(recipient);
        // The recipient must carry a concrete address; a chain-only ERC-7930 encoding parses to address(0),
        // which would collect value up-front yet never be executable and has no refund path.
        require(recipientAddress != address(0), ZeroAddress());

        _ensureL2ToL2(recipientChainId);

        (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) = parseAttributes(
            attributes,
            AttributeParsingRestrictions.CallAndBundleAttributes
        );
        // A single-call send is never atomic; reject a stray `atomicBundle` attribute rather than silently
        // ignoring it (`sendBundle` is the atomic entry point).
        require(!_parseAtomicSend(attributes).isAtomic, AtomicBundleNotAllowedInSendMessage());

        // Default the unbundler to the original sender pinned to this (source) chain — deliberately not
        // a chain wildcard, which would let a same-address clone on another chain unbundle. See
        // {protocol-docs/interop.md} (bundle attributes).
        if (bundleAttributes.unbundlerAddress.length == 0) {
            bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
        }

        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](1);
        callStartersInternal[0] = InteropCallStarterInternal({
            to: recipientAddress,
            data: payload,
            callAttributes: callAttributes
        });

        bytes[][] memory originalCallAttributes = new bytes[][](1);
        originalCallAttributes[0] = attributes;

        // This single-call send path is never atomic; pass an empty AtomicSend (publishes to L1 as usual).
        AtomicSend memory emptyAtomicSend;
        bytes32 bundleHash = _sendBundle({
            _destinationChainId: recipientChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes,
            _atomicSend: emptyAtomicSend
        });

        // The sendId of the single call in the bundle (see {protocol-docs/interop.md}, identifiers).
        sendId = keccak256(abi.encodePacked(bundleHash, uint256(0)));
    }

    /// @inheritdoc IInteropCenter
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable whenNotPaused nonReentrant returns (bytes32 bundleHash) {
        _ensureEmptyAddress(_destinationChainId);

        // slither-disable-next-line unused-return
        (uint256 destinationChainId, ) = InteroperableAddress.parseEvmV1Calldata(_destinationChainId);

        _ensureValidDestination(destinationChainId, _callStarters.length);
        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](
            _callStarters.length
        );
        uint256 callStartersLength = _callStarters.length;

        bytes[][] memory originalCallAttributes = new bytes[][](callStartersLength);

        for (uint256 i = 0; i < callStartersLength; ++i) {
            _ensureEmptyChainReference(_callStarters[i].to);

            // slither-disable-next-line unused-return
            (, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_callStarters[i].to);

            // Same guard as `sendMessage`: an ERC-7930 encoding with an empty address field parses to
            // address(0), which would collect value up-front for a call that can never execute and has
            // no refund path.
            require(recipientAddress != address(0), ZeroAddress());

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

        // Default the unbundler to the original sender pinned to this (source) chain — deliberately not
        // a chain wildcard, which would let a same-address clone on another chain unbundle. See
        // {protocol-docs/interop.md} (bundle attributes).
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

    /// @notice Validates the bundle destination: another L2, or L1 for a single-call bundle only.
    /// See {protocol-docs/interop.md} (restrictions) for the full destination rules; the ones that
    /// need parsed call attributes are enforced later in `_sendBundle`.
    /// @param _destinationChainId Destination chain ID.
    /// @param _callCount Number of calls in the bundle.
    function _ensureValidDestination(uint256 _destinationChainId, uint256 _callCount) internal view {
        require(L1_CHAIN_ID != block.chainid, CannotInitiateInteropOnL1(_destinationChainId));
        require(_destinationChainId != block.chainid, InteropToSelfNotSupported());
        if (_destinationChainId == L1_CHAIN_ID) {
            require(_callCount == 1, MultiCallToL1NotSupported(_callCount));
        }
    }

    /// @notice Strict L2->L2 destination check used by the generic single-message `sendMessage` entry point.
    /// @dev Unlike `_ensureValidDestination`, this never allows an L1 destination; the L2->L1 path
    /// goes through `sendBundle` (single-call bundle) instead.
    function _ensureL2ToL2(uint256 _destinationChainId) internal view {
        require(
            L1_CHAIN_ID != block.chainid && _destinationChainId != L1_CHAIN_ID,
            NotL2ToL2(block.chainid, _destinationChainId)
        );
        require(_destinationChainId != block.chainid, InteropToSelfNotSupported());
    }

    /// @notice Ensures `msg.value` matches the expected total for the bundle and burns/deposits the
    /// call value; charges the base-token protocol fee unless useFixedFee is set or the destination is
    /// L1 (L2->L1 bundles are free). See {protocol-docs/interop.md} (fee model, send flow).
    /// @param _destinationChainId Destination chain ID.
    /// @param _destinationBaseTokenAssetId The destination chain's base-token asset id (drives the
    /// same-vs-cross-base-token branch).
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

        uint256 protocolFee = (_useFixedFee || _destinationChainId == L1_CHAIN_ID)
            ? 0
            : interopProtocolFee * _callCount;

        if (_destinationBaseTokenAssetId == thisChainBaseTokenAssetId) {
            uint256 expectedValue = _totalBurnedCallsValue + _totalIndirectCallsValue + protocolFee;
            require(msg.value == expectedValue, MsgValueMismatch(expectedValue, msg.value));

            if (_totalBurnedCallsValue > 0) {
                // TODO(EVM-1395): unify same-base-token interop funding with the L2AssetRouter/L2NTV path
                // so InteropCenter does not need a dedicated BaseTokenHolder branch here.
                L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: _totalBurnedCallsValue}(_destinationChainId);
            }
        } else {
            uint256 expectedValue = _totalIndirectCallsValue + protocolFee;
            require(msg.value == expectedValue, MsgValueMismatch(expectedValue, msg.value));

            if (_totalBurnedCallsValue > 0) {
                IAssetRouterShared(_assetRouterAddr()).bridgehubDepositBaseToken(
                    _destinationChainId,
                    _destinationBaseTokenAssetId,
                    msg.sender,
                    _totalBurnedCallsValue
                );
            }
        }
        // Accumulate (rather than push) the fee: prevents a faulty coinbase from failing sends and
        // avoids calls to untrusted contracts during a send.
        if (protocolFee > 0) {
            accumulatedProtocolFees[block.coinbase] += protocolFee;
            emit ProtocolFeesAccumulated(block.coinbase, protocolFee);
        }
    }

    /// @notice Constructs, funds and dispatches an InteropBundle (both entry points funnel here).
    /// See {protocol-docs/interop.md} (send flow).
    /// @param _destinationChainId Chain ID to send to.
    /// @param _callStarters Array of InteropCallStarterInternal structs, corresponding to the calls in bundle.
    /// @param _bundleAttributes Attributes of the bundle.
    /// @param _originalCallAttributes Original ERC-7786 attributes for each call to emit in MessageSent events.
    /// @param _atomicSend Atomic send metadata (empty when the bundle is not atomic).
    /// @return bundleHash Hash of the sent bundle.
    function _sendBundle(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        BundleAttributes memory _bundleAttributes,
        bytes[][] memory _originalCallAttributes,
        AtomicSend memory _atomicSend
    ) internal returns (bytes32 bundleHash) {
        // An atomic bundle can never target L1 (no atomic execution there, and L2->L1 withdrawals must
        // never be revertable — see {protocol-docs/interop.md}, restrictions). Checked before any burn.
        if (_atomicSend.isAtomic) {
            require(_destinationChainId != L1_CHAIN_ID, AtomicBundleToL1NotSupported());
        }

        // Deliberately no gateway-mode requirement on the send side; correctness is enforced by the
        // receive-side proofs (see {protocol-docs/interop.md}, send flow).

        // A unique (sender, salt) pair guarantees a unique bundle hash.
        require(
            !isInteropBundleSaltUsed[msg.sender][_bundleAttributes.salt],
            InteropBundleSaltAlreadyUsed(msg.sender, _bundleAttributes.salt)
        );
        isInteropBundleSaltUsed[msg.sender][_bundleAttributes.salt] = true;

        // For an L2->L1 bundle the destination base token is the L1-native ETH asset id (L1 is not
        // registered in the L2 Bridgehub, and its base token is not necessarily this L2's).
        bytes32 destinationBaseTokenAssetId;
        if (_destinationChainId == L1_CHAIN_ID) {
            destinationBaseTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
        } else {
            destinationBaseTokenAssetId = L2_BRIDGEHUB.baseTokenAssetId(_destinationChainId);
            require(destinationBaseTokenAssetId != bytes32(0), DestinationChainNotRegistered(_destinationChainId));
        }
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            // See {protocol-docs/interop.md} (replay protection) for the salt scheme.
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
            if (_destinationChainId == L1_CHAIN_ID) {
                // Interop to L1 is restricted to a single indirect, zero-value asset-router call (a
                // withdrawal) for this release. See {protocol-docs/interop.md} (restrictions).
                require(_callStarters[i].callAttributes.indirectCall, DirectCallToL1NotSupported());
                require(
                    _callStarters[i].to == L2_ASSET_ROUTER_ADDR,
                    InteropCallToL1NotToAssetRouter(_callStarters[i].to)
                );
                require(
                    _callStarters[i].callAttributes.interopCallValue == 0,
                    NonZeroValueToL1NotSupported(_callStarters[i].callAttributes.interopCallValue)
                );
            }
            InteropCall memory interopCall = _processCallStarter(_callStarters[i], _destinationChainId, msg.sender);
            bundle.calls[i] = interopCall;
            totalBurnedCallsValue += _callStarters[i].callAttributes.interopCallValue;
            // For indirect calls, also account for the bridge message value that gets sent to the AssetRouter
            if (_callStarters[i].callAttributes.indirectCall) {
                totalIndirectCallsValue += _callStarters[i].callAttributes.indirectCallMessageValue;
            }
        }

        // Fixed ZK fees are accumulated per coinbase (not pushed) like the protocol fee above; L2->L1
        // bundles are free.
        if (_bundleAttributes.useFixedFee && _destinationChainId != L1_CHAIN_ID) {
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

        bytes32 msgHash;
        (bundleHash, msgHash) = _dispatchBundle(bundle, _atomicSend);

        _emitMessageSent({
            _calls: bundle.calls,
            _destinationChainId: _destinationChainId,
            _bundleHash: bundleHash,
            _callStarters: _callStarters,
            _originalCallAttributes: _originalCallAttributes
        });

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

    /// @notice Hashes the bundle and dispatches it: a normal bundle is published to L1 via
    /// {_sendBundleToL1}; an atomic bundle instead has its commit value appended to the interop IMT
    /// via {IAtomicFlowManager.append} (see {protocol-docs/interop.md}, atomic bundles).
    /// @dev `_atomicSend` travels out-of-band, never embedded in `_bundle`: `bundleHash` must stay
    /// independent of the flowId preimage (see {AtomicSend}).
    function _dispatchBundle(
        InteropBundle memory _bundle,
        AtomicSend memory _atomicSend
    ) internal returns (bytes32 bundleHash, bytes32 msgHash) {
        bytes memory interopBundleBytes = abi.encode(_bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(block.chainid, interopBundleBytes);

        if (_atomicSend.isAtomic) {
            _validateAtomicBundle(_bundle);
            IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).append({
                _bundleHash: bundleHash,
                _lowNullifierIndex: _atomicSend.lowNullifierIndex,
                _flowPreimage: _atomicSend.flowPreimage
            });
        } else {
            msgHash = _sendBundleToL1(interopBundleBytes, _bundle.calls.length);
        }
    }

    /// @notice Rejects atomic-bundle calls that carry native base-token `value` — the one thing timeout
    /// recovery can never reverse. See {protocol-docs/interop.md} (restrictions).
    /// @dev Every atomic send passes through {_dispatchBundle}, so this covers all atomic bundles.
    function _validateAtomicBundle(InteropBundle memory _bundle) internal pure {
        uint256 callsLength = _bundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            InteropCall memory currentCall = _bundle.calls[i];
            if (currentCall.value != 0) {
                revert AtomicBundleCallCarriesValue(i, currentCall.value);
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

    /// @notice Turns a call starter into an `InteropCall` — as-is for direct calls, via the target's
    /// `initiateIndirectCall` for indirect ones. See {protocol-docs/interop.md} (direct vs indirect).
    function _processCallStarter(
        InteropCallStarterInternal memory _callStarter,
        uint256 _destinationChainId,
        address _sender
    ) internal returns (InteropCall memory interopCall) {
        address recipientAddress = _callStarter.to;

        if (_callStarter.callAttributes.indirectCall) {
            // Whether a particular indirect path supports non-zero interopCallValue is defined by the
            // concrete IL2CrossChainSender implementation (the current L2AssetRouter/NTV path does not).
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
    function forwardTransactionOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlySettlementLayerRelayedSender {
        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
        if (zkChain == address(0)) {
            revert DestinationChainNotRegistered(_chainId);
        }

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
                // Only validated here (permitted, non-duplicate); the payload is parsed separately by
                // `_parseAtomicSend` and never stored in `BundleAttributes` (see {AtomicSend}).
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
    /// by `parseAttributes`); `isAtomic = false` when the attribute is absent. Kept separate from
    /// `BundleAttributes` so the metadata never enters the cross-chain bundle (see {AtomicSend}).
    function _parseAtomicSend(bytes[] calldata _attributes) internal pure returns (AtomicSend memory atomicSend) {
        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            if (bytes4(_attributes[i]) == IERC7786Attributes.atomicBundle.selector) {
                (atomicSend.flowPreimage, atomicSend.lowNullifierIndex) = AttributesDecoder.decodeAtomicBundle(
                    _attributes[i]
                );
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
