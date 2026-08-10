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

import {SETTLEMENT_LAYER_RELAY_SENDER, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
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
    NonAtomicSendUnsupported,
    AtomicBundleToL1NotSupported,
    InteropPreviewHash,
    CannotInitiateInteropOnL1,
    DestinationChainNotRegistered,
    DirectCallToL1NotSupported,
    IndirectCallCannotCarryValue,
    IndirectCallOnlyToAssetRouter,
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
import {IInteropAttributeParser} from "./IInteropAttributeParser.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {IAtomicFlowManager} from "../atomic-interop/IAtomicFlowManager.sol";
import {ERC7930_V1_MIN_LENGTH} from "./InteropConstants.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {IL2CrossChainSender} from "../bridge/interfaces/IL2CrossChainSender.sol";
import {IAssetRouterShared} from "../bridge/asset-router/IAssetRouterShared.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";

/// @dev Default fixed ZK fee per interop call; intentionally above the intended dynamic fee to
/// incentivize the dynamic path. See {protocol-docs/interop.md#fee-model}.
uint256 constant DEFAULT_ZK_INTEROP_FEE = 10e18;

/// @title InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Primary entry point for interop between chains: forms interop bundles and dispatches them
/// (L2->L1 message, or IMT commit for atomic bundles). Deployed on L2s only as of v31.
/// See {protocol-docs/interop.md#zksync-interop-protocol}.
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
    ///      protection; see {protocol-docs/interop.md#fee-model}.
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
    ///      once, which makes every emitted bundle hash unique. See
    ///      {protocol-docs/interop.md#replay-protection-and-bundle-uniqueness}.
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

    /// @inheritdoc IInteropCenter
    function getZKTokenAddress() public view returns (address) {
        if (address(zkToken) != address(0)) {
            return address(zkToken);
        }
        return IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT).tokenAddress(ZK_TOKEN_ASSET_ID);
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

        // Default the unbundler to the original sender pinned to this (source) chain — deliberately not
        // a chain wildcard, which would let a same-address clone on another chain unbundle. See
        // {protocol-docs/interop.md#bundle-attributes-bundleattributes}.
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

        // Every send is atomic now (public interop was removed). A single-call send is a valid
        // single-leg atomic flow: it must carry the `atomicBundle` attribute like any other send.
        AtomicSend memory atomicSend = _parser().parseAtomicSend(attributes);

        bytes32 bundleHash = _sendBundle({
            _destinationChainId: recipientChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes,
            _atomicSend: atomicSend
        });

        // The sendId of the single call in the bundle (see {protocol-docs/interop.md#identifiers-and-hashes}).
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

        // Ensure the destination is valid: bundles are initiated only on an L2, never target this chain
        // itself, and an L2->L1 bundle (canonically a withdrawal) must be a single call.
        require(L1_CHAIN_ID != block.chainid, CannotInitiateInteropOnL1(destinationChainId));
        require(destinationChainId != block.chainid, InteropToSelfNotSupported());
        if (destinationChainId == L1_CHAIN_ID) {
            require(_callStarters.length == 1, MultiCallToL1NotSupported(_callStarters.length));
        }

        (
            InteropCallStarterInternal[] memory callStartersInternal,
            BundleAttributes memory bundleAttributes,
            bytes[][] memory originalCallAttributes
        ) = _parseBundleInputs(_callStarters, _bundleAttributes);

        AtomicSend memory atomicSend = _parser().parseAtomicSend(_bundleAttributes);

        bundleHash = _sendBundle({
            _destinationChainId: destinationChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes,
            _atomicSend: atomicSend
        });
    }

    /// @inheritdoc IInteropCenter
    function previewBundleHash(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external {
        _ensureEmptyAddress(_destinationChainId);
        // slither-disable-next-line unused-return
        (uint256 destinationChainId, ) = InteroperableAddress.parseEvmV1Calldata(_destinationChainId);
        _ensureL2ToL2(destinationChainId);

        // Shares the send path's input parsing so the previewed hash is byte-identical to sendBundle's.
        // The original call attributes (event data) are irrelevant to the hash, so they are discarded here.
        // slither-disable-next-line unused-return
        (
            InteropCallStarterInternal[] memory callStartersInternal,
            BundleAttributes memory bundleAttributes,

        ) = _parseBundleInputs(_callStarters, _bundleAttributes);

        _previewBundleHashAndRevert(destinationChainId, callStartersInternal, bundleAttributes);
    }

    /// @inheritdoc IInteropCenter
    function previewMessageHash(
        bytes calldata _recipient,
        bytes calldata _payload,
        bytes[] calldata _attributes
    ) external {
        // slither-disable-next-line unused-return
        (uint256 recipientChainId, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_recipient);
        _ensureL2ToL2(recipientChainId);
        // Mirror `sendMessage`'s guard so the preview rejects a chain-only (address(0)) recipient exactly as
        // the real send would, keeping the previewed hash faithful to what `sendMessage` accepts.
        require(recipientAddress != address(0), ZeroAddress());

        (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) = parseAttributes(
            _attributes,
            AttributeParsingRestrictions.CallAndBundleAttributes
        );
        if (bundleAttributes.unbundlerAddress.length == 0) {
            bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
        }

        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](1);
        callStartersInternal[0] = InteropCallStarterInternal({
            to: recipientAddress,
            data: _payload,
            callAttributes: callAttributes
        });

        _previewBundleHashAndRevert(recipientChainId, callStartersInternal, bundleAttributes);
    }

    /// @notice Shared tail of the preview quoters ({previewBundleHash}/{previewMessageHash}): assembles the
    /// bundle from already-parsed inputs and reverts with its hash.
    /// @dev Quoter pattern: this runs the same stateful assembly as `sendBundle` (including the value-burning
    /// `initiateIndirectCall` for indirect legs), so it MUST NOT commit that burn on-chain. Reverting with the
    /// hash — instead of returning it — rolls back every state change made while assembling, regardless of
    /// caller/context; callers read the hash from the `InteropPreviewHash` revert via a static `eth_call`. It
    /// intentionally stops BEFORE the atomic append (unlike the real dispatch): the flow's `flowId` commits to
    /// this very bundle hash, so the hash must be predictable before any flow exists (a chicken-and-egg that a
    /// `submitBundle`-then-revert form could not satisfy).
    function _previewBundleHashAndRevert(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        BundleAttributes memory _bundleAttributes
    ) private {
        // slither-disable-next-line unused-return
        (InteropBundle memory bundle, , ) = _buildInteropBundle(_destinationChainId, _callStarters, _bundleAttributes);
        revert InteropPreviewHash(_hashBundle(bundle));
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that the ERC-7930 address has an empty ChainReference field.
    /// @dev Ensures that CallStarters in `sendBundle` do not include a ChainReference, as required by our
    ///      implementation. The ChainReference length is stored at byte offset 0x04 in the ERC-7930 format.
    /// @dev Takes `bytes memory` so one implementation serves both user-supplied (calldata, implicitly
    ///      copied — these addresses are tens of bytes) and runtime-produced (an indirect call starter's
    ///      returned recipient) values.
    /// @param _interoperableAddress The ERC-7930 address to verify.
    function _ensureEmptyChainReference(bytes memory _interoperableAddress) internal pure {
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        require(
            uint8(_interoperableAddress[0x04]) == 0,
            InteroperableAddressChainReferenceNotEmpty(_interoperableAddress)
        );
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

    /// @notice Strict L2->L2 destination check used by the generic single-message `sendMessage` entry point.
    /// @dev Unlike the `sendBundle` destination check, this never allows an L1 destination; the L2->L1 path
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
    /// L1 (L2->L1 bundles are free). See {protocol-docs/interop.md#fee-model} and
    /// {protocol-docs/interop.md#send-flow}.
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
        bytes32 thisChainBaseTokenAssetId = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT).BASE_TOKEN_ASSET_ID();

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
                IAssetRouterShared(L2_ASSET_ROUTER_ADDR).bridgehubDepositBaseToken(
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

    /// @notice Parses the raw `sendBundle`/`previewBundleHash` inputs into the internal representation shared
    /// by the real send and the hash preview: resolves each call starter's recipient address and per-call
    /// attributes, captures the original per-call attributes (for `MessageSent` events), parses the bundle
    /// attributes and defaults the unbundler to the sender.
    /// @dev Does NOT validate the destination — `sendBundle` allows L2->L1 withdrawals while the previews are
    /// L2<->L2 only, so each caller runs its own destination check before calling this.
    /// @param _callStarters Raw call starters (ERC-7930 recipient + calldata + ERC-7786 attributes).
    /// @param _bundleAttributes Raw ERC-7786 bundle attributes.
    /// @return callStartersInternal Resolved call starters ready for `_buildInteropBundle`.
    /// @return bundleAttributes Parsed bundle attributes, with the unbundler defaulted to `msg.sender`.
    /// @return originalCallAttributes Per-call original attributes, preserved for `MessageSent` emission.
    function _parseBundleInputs(
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    )
        internal
        view
        returns (
            InteropCallStarterInternal[] memory callStartersInternal,
            BundleAttributes memory bundleAttributes,
            bytes[][] memory originalCallAttributes
        )
    {
        uint256 callStartersLength = _callStarters.length;
        callStartersInternal = new InteropCallStarterInternal[](callStartersLength);
        originalCallAttributes = new bytes[][](callStartersLength);

        for (uint256 i = 0; i < callStartersLength; ++i) {
            _ensureEmptyChainReference(_callStarters[i].to);

            // slither-disable-next-line unused-return
            (, address recipientAddress) = InteroperableAddress.parseEvmV1Calldata(_callStarters[i].to);

            // Same guard as `sendMessage`: an ERC-7930 encoding with an empty address field parses to
            // address(0), which would collect value up-front for a call that can never execute and has no
            // refund path. Reject it here (during parsing) so it surfaces before any later validation.
            require(recipientAddress != address(0), ZeroAddress());

            // Store original attributes for MessageSent event emission.
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
        (, bundleAttributes) = parseAttributes(_bundleAttributes, AttributeParsingRestrictions.OnlyBundleAttributes);

        // If the unbundler was not set for a bundle, we set the unbundler to be equal to the original sender, so
        // that it's still possible to unbundle the bundle. If the original sender is the contract, it'll still be
        // able to unbundle the bundle either via direct call to `unbundleBundle`, or via `sendMessage` to
        // `L2InteropHandler`, with specific payload. Refer to `L2InteropHandler` for details.
        if (bundleAttributes.unbundlerAddress.length == 0) {
            bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
        }
    }

    /// @notice Constructs, funds and dispatches an InteropBundle (both entry points funnel here).
    /// See {protocol-docs/interop.md#send-flow}.
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
        // Reject invalid atomicity/destination combinations up front, before any stateful bundle assembly
        // or value burn (both `sendMessage` and `sendBundle` funnel through here). Exactly one destination is
        // valid per atomicity:
        //  - Atomic  => an L2 destination. An atomic bundle can never target L1: it is not published as an
        //    L2->L1 message (its commit value goes to the IMT instead) and L1 has no atomic execution, so
        //    its only possible outcome would be a timeout refund — but L2->L1 withdrawals must never be
        //    revertable (their `totalWithdrawalsToL1` accounting is consumed once during the L1->GW migration
        //    and must stay append-only, see {L2AssetTracker}).
        //  - Non-atomic => L1 (an L2->L1 withdrawal). Public (L1-published) L2->L2 interop was removed, so a
        //    non-atomic L2->L2 send has no delivery path.
        // The empty call-starter address (`ZeroAddress`) is already rejected earlier in `_parseBundleInputs`;
        // `DestinationChainNotRegistered` for a bad L2 destination still surfaces from the assembly below.
        if (_atomicSend.isAtomic) {
            require(_destinationChainId != L1_CHAIN_ID, AtomicBundleToL1NotSupported());
        } else {
            require(_destinationChainId == L1_CHAIN_ID, NonAtomicSendUnsupported());
        }

        // Deliberately no gateway-mode requirement on the send side; correctness is enforced by the
        // receive-side proofs (see {protocol-docs/interop.md#send-flow}).

        // A unique (sender, salt) pair guarantees a unique bundle hash.
        require(
            !isInteropBundleSaltUsed[msg.sender][_bundleAttributes.salt],
            InteropBundleSaltAlreadyUsed(msg.sender, _bundleAttributes.salt)
        );
        isInteropBundleSaltUsed[msg.sender][_bundleAttributes.salt] = true;

        // Form an InteropBundle (this also runs each call starter, burning value for indirect calls, and
        // enforcing the L2->L1 withdrawal restrictions for an L1 destination).
        (
            InteropBundle memory bundle,
            uint256 totalBurnedCallsValue,
            uint256 totalIndirectCallsValue
        ) = _buildInteropBundle(_destinationChainId, _callStarters, _bundleAttributes);

        uint256 callStartersLength = _callStarters.length;
        // Fixed ZK fees are accumulated per coinbase (not pushed) like the protocol fee above; L2->L1
        // bundles are free.
        if (_bundleAttributes.useFixedFee && _destinationChainId != L1_CHAIN_ID) {
            uint256 totalZKFee = ZK_INTEROP_FEE * callStartersLength;
            _getZKToken().safeTransferFrom(msg.sender, address(this), totalZKFee);
            accumulatedZKFees[block.coinbase] += totalZKFee;
            emit FixedZKFeesAccumulated(msg.sender, block.coinbase, totalZKFee);
        }

        // Ensure that tokens required for bundle execution were received.
        _ensureCorrectTotalValue({
            _destinationChainId: bundle.destinationChainId,
            _destinationBaseTokenAssetId: bundle.destinationBaseTokenAssetId,
            _totalBurnedCallsValue: totalBurnedCallsValue,
            _totalIndirectCallsValue: totalIndirectCallsValue,
            _useFixedFee: _bundleAttributes.useFixedFee,
            _callCount: callStartersLength
        });

        // Hash the bundle and dispatch it. For an L2->L2 bundle this appends the commit value to the interop
        // IMT via the AtomicFlowManager (atomic-only); for an L2->L1 withdrawal it publishes the bundle to L1.
        // The atomic send metadata travels out-of-band (`_atomicSend`), not embedded in the bundle, so
        // `bundleHash` does not depend on `flowId` (a circular dependency). `msgHash` is the L2->L1 message
        // hash for a withdrawal, or `bytes32(0)` for an atomic L2->L2 bundle.
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

    /// @notice Assembles the {InteropBundle} from resolved call starters: derives the sender-scoped salt,
    /// resolves the destination base-token asset id, and processes each call starter (which, for indirect
    /// calls, executes the value-burning `initiateIndirectCall`). Returns the bundle plus the aggregated
    /// call values needed for source-chain value collection.
    /// @dev Shared by {_sendBundle} (the real send) and the {previewBundleHash}/{previewMessageHash}
    /// simulations, so a preview's `bundleHash` is byte-identical to the value the matching send emits.
    function _buildInteropBundle(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        BundleAttributes memory _bundleAttributes
    ) internal returns (InteropBundle memory bundle, uint256 totalBurnedCallsValue, uint256 totalIndirectCallsValue) {
        // For an L2->L1 bundle the L1 chain is not registered as an interop destination in the L2 Bridgehub,
        // so its base-token asset id is the L1-native ETH asset id (which is NOT necessarily this L2's base
        // token — they only coincide on ETH-based chains). Otherwise resolve it from the Bridgehub registry.
        bytes32 destinationBaseTokenAssetId = _destinationChainId == L1_CHAIN_ID
            ? DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS)
            : _getDestinationBaseTokenAssetId(_destinationChainId);
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            // See {protocol-docs/interop.md#replay-protection-and-bundle-uniqueness} for the salt scheme.
            interopBundleSalt: keccak256(abi.encodePacked(msg.sender, _bundleAttributes.salt)),
            calls: new InteropCall[](_callStarters.length),
            bundleAttributes: _bundleAttributes
        });

        // Fill the formed InteropBundle with calls, aggregating the value each one consumes.
        uint256 callStartersLength = _callStarters.length;
        for (uint256 i = 0; i < callStartersLength; ++i) {
            if (_destinationChainId == L1_CHAIN_ID) {
                // Interop to L1 is restricted to a single indirect, zero-value asset-router call (a
                // withdrawal) for this release. See {protocol-docs/interop.md#restrictions}.
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
            if (_callStarters[i].callAttributes.indirectCall) {
                // Indirect calls are restricted to the L2 asset router for this release: the atomic
                // timeout-recovery hook is dispatched to the asset router only, so pinning the starter
                // guarantees every indirect burn is reachable by recovery. See
                // {protocol-docs/interop.md#restrictions}. (For L1 destinations the more specific
                // `InteropCallToL1NotToAssetRouter` above fires first — keep that ordering.)
                require(
                    _callStarters[i].to == L2_ASSET_ROUTER_ADDR,
                    IndirectCallOnlyToAssetRouter(_callStarters[i].to)
                );
                // Indirect calls must not carry destination-side value (`interopCallValue`): on the atomic
                // timeout recovery path the value is refunded to `InteropCall.from` (the indirect sender),
                // not the payer, so it would strand funds. All L2->L2 bundles are atomic, so the ban is
                // unconditional here. (`indirectCallMessageValue` — the source-side value passed to
                // `initiateIndirectCall` — stays allowed.)
                require(
                    _callStarters[i].callAttributes.interopCallValue == 0,
                    IndirectCallCannotCarryValue(_callStarters[i].callAttributes.interopCallValue)
                );
            }
            InteropCall memory interopCall = _processCallStarter(_callStarters[i], _destinationChainId);
            bundle.calls[i] = interopCall;
            totalBurnedCallsValue += _callStarters[i].callAttributes.interopCallValue;
            // For indirect calls, also account for the bridge message value that gets sent to the AssetRouter
            if (_callStarters[i].callAttributes.indirectCall) {
                totalIndirectCallsValue += _callStarters[i].callAttributes.indirectCallMessageValue;
            }
        }
    }

    /// @notice Hashes an assembled {InteropBundle} into its canonical `bundleHash`.
    function _hashBundle(InteropBundle memory _bundle) internal view returns (bytes32) {
        return InteropDataEncoding.encodeInteropBundleHash(abi.encode(_bundle));
    }

    /// @notice Returns the base token asset ID for the destination chain. Override for pre-v31 chains.
    function _getDestinationBaseTokenAssetId(uint256 _destinationChainId) internal view virtual returns (bytes32) {
        bytes32 assetId = L2_BRIDGEHUB.baseTokenAssetId(_destinationChainId);
        require(assetId != bytes32(0), DestinationChainNotRegistered(_destinationChainId));
        return assetId;
    }

    /// @notice Handles base-token value collection for the bundle.
    /// @notice Hashes the bundle and dispatches it along one of two paths, keyed on the destination:
    /// - **L2->L2 interop (atomic):** the bundle's commit value is appended to the interop IMT via the
    ///   {AtomicFlowManager} and is NOT published to L1 — source-side funds were already collected earlier in
    ///   the send (`initiateIndirectCall` for indirect asset-transfer calls, `_ensureCorrectTotalValue` for a
    ///   direct call's value; a fund-free direct call collects nothing), and the destination executes it via
    ///   {L2InteropHandler.executeAtomicBundle}.
    ///   Native-`value` legs are allowed: the base-token value collected at send time (via the base-token
    ///   holder for the same base token, or the asset router for a different one) is refunded to the payer on
    ///   timeout by {AtomicFlowManager._recoverBundle}. Atomicity/destination validity (atomic must be L2,
    ///   non-atomic must be L1) is already enforced up front in {_sendBundle}.
    /// - **L2->L1 withdrawal:** the `BUNDLE_IDENTIFIER`-prefixed bundle is published to L1 via the L2->L1
    ///   messenger and finalized there by {L1InteropHandler}, which proves the message inclusion. Withdrawals
    ///   are not atomic (they inherently target L1), so they carry no `atomicBundle` attribute.
    /// @dev `_atomicSend` (the {AtomicFlowPreimage} plus `lowNullifierIndex`) is passed out-of-band and is intentionally
    /// NOT embedded in `_bundle`, so `bundleHash` is independent of `flowId`. This is required:
    /// `flowId = keccak256(abi.encode(AtomicFlowPreimage))` (whose `legBundleHashes` include this bundle's hash)
    /// must be computable off-chain before the send, which is impossible if a `bundleHash` (a flowId
    /// input) embedded `flowId`.
    /// @return bundleHash Canonical hash of the bundle.
    /// @return msgHash The L2->L1 message hash for a withdrawal, or `bytes32(0)` for an atomic L2->L2 bundle.
    function _dispatchBundle(
        InteropBundle memory _bundle,
        AtomicSend memory _atomicSend
    ) internal returns (bytes32 bundleHash, bytes32 msgHash) {
        bundleHash = _hashBundle(_bundle);

        if (_bundle.destinationChainId == L1_CHAIN_ID) {
            // L2->L1 withdrawal: publish the bundle to L1 for finalization by the L1InteropHandler.
            msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(bytes.concat(BUNDLE_IDENTIFIER, abi.encode(_bundle)));
            return (bundleHash, msgHash);
        }

        // L2->L2 interop: atomic-only (`_sendBundle` already guaranteed `isAtomic` for a non-L1 destination
        // and rejected atomic-to-L1). Append the leg's commit value to the interop IMT. The AtomicFlowManager
        // recomputes `flowId` from the out-of-band preimage and requires `bundleHash` to be one of its legs.
        IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).append({
            _bundleHash: bundleHash,
            _lowNullifierIndex: _atomicSend.lowNullifierIndex,
            _flowPreimage: _atomicSend.flowPreimage
        });
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
    /// `initiateIndirectCall` for indirect ones. See {protocol-docs/interop.md#direct-vs-indirect-calls}.
    function _processCallStarter(
        InteropCallStarterInternal memory _callStarter,
        uint256 _destinationChainId
    ) internal returns (InteropCall memory interopCall) {
        address recipientAddress = _callStarter.to;

        if (_callStarter.callAttributes.indirectCall) {
            // `interopCallValue` is already required to be zero for every indirect call (see the
            // `IndirectCallCannotCarryValue` check in `_buildInteropBundle`); it is still forwarded so the
            // returned starter can be checked against it (`IndirectCallValueMismatch`). Only
            // `indirectCallMessageValue` (source-side `msg.value`) actually moves value here.
            // slither-disable-next-line arbitrary-send-eth
            InteropCallStarter memory actualCallStarter = IL2CrossChainSender(recipientAddress).initiateIndirectCall{
                value: _callStarter.callAttributes.indirectCallMessageValue
            }(_destinationChainId, msg.sender, _callStarter.callAttributes.interopCallValue, _callStarter.data);
            // solhint-disable-next-line no-unused-vars
            // slither-disable-next-line unused-return
            (CallAttributes memory indirectCallAttributes, ) = _parser().parseAttributes(
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
            // The indirect call starter is pinned to the asset router (`IndirectCallOnlyToAssetRouter`,
            // checked in `_buildInteropBundle`), but its returned recipient still gets the same
            // validation a user-supplied call starter's `to` gets in `_parseBundleInputs`:
            // the chain reference must be empty (the bundle-level destination chain is authoritative — a
            // starter must not smuggle a different chain id that would otherwise be silently ignored)
            // and the address must be non-zero (a zero recipient could never execute and has no refund
            // path for the value already collected).
            _ensureEmptyChainReference(actualCallStarter.to);
            // slither-disable-next-line unused-return
            (, address actualCallRecipient) = InteroperableAddress.parseEvmV1(actualCallStarter.to);
            require(actualCallRecipient != address(0), ZeroAddress());
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
                from: msg.sender
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
    /// @dev Thin forwarder to the stateless {InteropAttributeParser} built-in. The parsing logic was moved out
    /// of this contract to keep it under the EIP-170 runtime code-size limit; kept here for ABI compatibility.
    function parseAttributes(
        bytes[] calldata _attributes,
        AttributeParsingRestrictions _restriction
    ) public pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) {
        // The tuple IS returned to our caller; slither's unused-return misfires on `return extCall()`.
        // slither-disable-next-line unused-return
        return _parser().parseAttributes(_attributes, _restriction);
    }

    /// @inheritdoc IERC7786GatewaySource
    /// @dev Thin forwarder to the stateless {InteropAttributeParser} built-in (see {parseAttributes}).
    function supportsAttribute(bytes4 _attributeSelector) external pure override returns (bool) {
        return _parser().supportsAttribute(_attributeSelector);
    }

    /// @notice The stateless attribute parser deployed at its fixed built-in address.
    function _parser() private pure returns (IInteropAttributeParser) {
        return IInteropAttributeParser(L2_INTEROP_ATTRIBUTE_PARSER_ADDR);
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
