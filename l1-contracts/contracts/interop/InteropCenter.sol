// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IInteropCenter} from "./IInteropCenter.sol";

import {GW_ASSET_TRACKER, L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BRIDGEHUB, L2_COMPLEX_UPGRADER_ADDR, L2_NATIVE_TOKEN_VAULT, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractAddresses.sol";

import {ETH_TOKEN_ADDRESS, SERVICE_TRANSACTION_SENDER, SETTLEMENT_LAYER_RELAY_SENDER} from "../common/Config.sol";
import {BUNDLE_IDENTIFIER, BalanceChange, BundleAttributes, CallAttributes, INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION, InteropBundle, InteropCall, InteropCallStarter, InteropCallStarterInternal} from "../common/Messaging.sol";
import {MsgValueMismatch, NotL1, NotL2ToL2, Unauthorized} from "../common/L1ContractErrors.sol";
import {NotInGatewayMode} from "../core/bridgehub/L1BridgehubErrors.sol";

import {AttributeAlreadySet, AttributeViolatesRestriction, DestinationChainNotRegistered, IndirectCallValueMismatch, InteroperableAddressChainReferenceNotEmpty, InteroperableAddressNotEmpty, UseFixedFeeRequired, FeeWithdrawalFailed, ZKTokenNotAvailable} from "./InteropErrors.sol";

import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {IL2CrossChainSender} from "../bridge/interfaces/IL2CrossChainSender.sol";
import {IAssetRouterShared} from "../bridge/asset-router/IAssetRouterShared.sol";

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

    /// @notice The asset ID of ETH on L1.
    bytes32 internal ETH_TOKEN_ASSET_ID;

    /// @notice This mapping stores a number of interop bundles sent by an individual sender.
    ///         It's being used to derive interopBundleSalt in InteropBundle struct, whose role
    ///         is to ensure that each bundle has a unique hash.
    mapping(address sender => uint256 numberOfBundlesSent) public interopBundleNonce;

    /// @notice Operator-set fee in base token per interop call (when useFixedFee=false).
    uint256 public interopProtocolFee;

    /// @notice Fixed fee amount in ZK tokens per interop call (when useFixedFee=true).
    /// @dev This is intentionally set to be the more expensive option compared to dynamic base token fees.
    ///      The fixed ZK fee provides Stage 1 protection - it allows users to pay fees independent of chain
    ///      operator settings, ensuring interop works even if the operator sets arbitrary dynamic fees.
    /// TODO: Decide on the exact value for fixed fee.
    uint256 public constant ZK_INTEROP_FEE = 1e18;

    /// @notice ZK token asset ID for resolving token address via native token vault.
    bytes32 public ZK_TOKEN_ASSET_ID;

    /// @notice Cached ZK token contract address (resolved from asset ID).
    IERC20 private zkToken;

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

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Only allows calls from the service transaction sender (L1 Admin.sol via requestL2ServiceTransaction).
    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    /// @notice Returns ZK token address if available, zero address otherwise.
    /// @dev View function to check ZK token availability without modifying state.
    /// @return The ZK token address or zero address if not available.
    function getZKTokenAddress() public view returns (address) {
        // Check cached token first
        if (address(zkToken) != address(0)) {
            return address(zkToken);
        }

        // Try to resolve from asset ID
        return L2_NATIVE_TOKEN_VAULT.tokenAddress(ZK_TOKEN_ASSET_ID);
    }

    /// @notice Resolves ZK token address from asset ID with caching.
    /// @dev Uses native token vault to resolve asset ID to token address.
    /// @dev Reverts with ZKTokenNotAvailable() if ZK token hasn't been bridged to this chain yet.
    ///      This means useFixedFee=true is only available after ZK token is bridged to the source chain.
    /// @return The ZK token contract interface.
    function _getZKToken() internal returns (IERC20) {
        // Return cached token if available
        if (address(zkToken) != address(0)) {
            return zkToken;
        }

        address tokenAddress = getZKTokenAddress();
        require(tokenAddress != address(0), ZKTokenNotAvailable());

        // Cache the resolved token
        zkToken = IERC20(tokenAddress);
        return zkToken;
    }

    /// @notice To avoid parity hack
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        bytes32 _zkTokenAssetId
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        L1_CHAIN_ID = _l1ChainId;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
        ZK_TOKEN_ASSET_ID = _zkTokenAssetId;

        _transferOwnership(_owner);
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
    ) public payable whenNotPaused returns (bytes32 sendId) {
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
    /// @param _destinationChainId Chain ID to send to. It's an ERC-7930 address that MUST have an empty address field, and encodes an EVM destination chain ID.
    /// @param _callStarters Array of call descriptors. The ERC-7930 address in each callStarter.to
    ///                      MUST have an empty ChainReference field. We assume all of the calls should go to the _destinationChainId,
    ///                      so specifying the chain ID in _callStarters is redundant.
    /// @param _bundleAttributes Attributes of the bundle.
    /// @return bundleHash Hash of the sent bundle.
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable whenNotPaused returns (bytes32 bundleHash) {
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

        bundleHash = _sendBundle({
            _destinationChainId: destinationChainId,
            _callStarters: callStartersInternal,
            _bundleAttributes: bundleAttributes,
            _originalCallAttributes: originalCallAttributes
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
            _interoperableAddress.length >= 5,
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
            _interoperableAddress.length >= 5,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 chainReferenceLength = uint8(_interoperableAddress[0x04]);
        require(
            _interoperableAddress.length >= 6 + chainReferenceLength,
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
        uint256 _totalBurnedCallsValue,
        uint256 _totalIndirectCallsValue,
        bool _useFixedFee,
        uint256 _callCount
    ) internal {
        bytes32 destinationChainBaseTokenAssetId = L2_BRIDGEHUB.baseTokenAssetId(_destinationChainId);
        require(destinationChainBaseTokenAssetId != bytes32(0), DestinationChainNotRegistered(_destinationChainId));
        // We burn the value that is passed along the bundle here, on source chain.
        bytes32 thisChainBaseTokenAssetId = L2_BRIDGEHUB.baseTokenAssetId(block.chainid);

        // Calculate protocol fee - only charge base token fee if not using fixed ZK fees.
        // Fee is charged per-call.
        uint256 protocolFee = _useFixedFee ? 0 : interopProtocolFee * _callCount;

        if (destinationChainBaseTokenAssetId == thisChainBaseTokenAssetId) {
            uint256 expectedValue = _totalBurnedCallsValue + _totalIndirectCallsValue + protocolFee;
            require(msg.value == expectedValue, MsgValueMismatch(expectedValue, msg.value));

            // Burn user value for interop calls.
            if (_totalBurnedCallsValue > 0) {
                // slither-disable-next-line arbitrary-send-eth
                L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue{value: _totalBurnedCallsValue}();
            }
        } else {
            uint256 expectedValue = _totalIndirectCallsValue + protocolFee;
            require(msg.value == expectedValue, MsgValueMismatch(expectedValue, msg.value));

            // Handle cross-chain token deposit for different base tokens
            if (_totalBurnedCallsValue > 0) {
                IAssetRouterShared(L2_ASSET_ROUTER_ADDR).bridgehubDepositBaseToken(
                    _destinationChainId,
                    destinationChainBaseTokenAssetId,
                    msg.sender,
                    _totalBurnedCallsValue
                );
            }
        }
        // Send protocol fee directly to block.coinbase
        if (protocolFee > 0) {
            (bool success, ) = block.coinbase.call{value: protocolFee}("");
            require(success, FeeWithdrawalFailed());
            emit ProtocolFeesCollected(block.coinbase, protocolFee);
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
        require(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() != L1_CHAIN_ID, NotInGatewayMode());

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

        // This will calculate how much value does all of the calls use cumulatively.
        uint256 totalBurnedCallsValue;
        uint256 totalIndirectCallsValue;

        // Fill the formed InteropBundle with calls.
        uint256 callStartersLength = _callStarters.length;
        for (uint256 i = 0; i < callStartersLength; ++i) {
            InteropCall memory interopCall = _processCallStarter(_callStarters[i], _destinationChainId, msg.sender);
            bundle.calls[i] = interopCall;
            totalBurnedCallsValue += _callStarters[i].callAttributes.interopCallValue;
            // For indirect calls, also account for the bridge message value that gets sent to the AssetRouter
            if (_callStarters[i].callAttributes.indirectCall) {
                totalIndirectCallsValue += _callStarters[i].callAttributes.indirectCallMessageValue;
            }
        }

        // If using fixed fees, collect ZK tokens per-call and send to block.coinbase
        if (_bundleAttributes.useFixedFee) {
            uint256 totalZKFee = ZK_INTEROP_FEE * callStartersLength;
            _getZKToken().safeTransferFrom(msg.sender, block.coinbase, totalZKFee);
            emit FixedZKFeesCollected(msg.sender, block.coinbase, totalZKFee);
        }

        // Ensure that tokens required for bundle execution were received.
        // solhint-disable-next-line
        _ensureCorrectTotalValue(
            bundle.destinationChainId,
            totalBurnedCallsValue,
            totalIndirectCallsValue,
            _bundleAttributes.useFixedFee,
            callStartersLength
        );

        bytes32 msgHash;
        /// To avoid stack too deep error
        {
            bytes memory interopBundleBytes = abi.encode(bundle);

            // Send the message corresponding to the relevant InteropBundle to L1.
            msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(bytes.concat(BUNDLE_IDENTIFIER, interopBundleBytes));
            bundleHash = InteropDataEncoding.encodeInteropBundleHash(block.chainid, interopBundleBytes);
        }

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
        // Use the already-parsed address from InteropCallStarterInternal
        address recipientAddress = _callStarter.to;

        if (_callStarter.callAttributes.indirectCall) {
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

    /// @notice Forwards a transaction from the gateway to a chain mailbox (from L1).
    /// @dev Note, that `_canonicalTxHash` is provided by the chain and so should not be trusted to be unique,
    /// while the rest of the fields are trusted to be populated correctly inside the `Mailbox` of the Gateway.
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
        _balanceChange.baseTokenAssetId = L2_BRIDGEHUB.baseTokenAssetId(_chainId);
        GW_ASSET_TRACKER.handleChainBalanceIncreaseOnGateway({
            _chainId: _chainId,
            _canonicalTxHash: _canonicalTxHash,
            _balanceChange: _balanceChange
        });

        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
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

        bytes4[5] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
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
            } else {
                revert IERC7786GatewaySource.UnsupportedAttribute(selector);
            }
        }

        // Enforce useFixedFee attribute as required for all interop calls. This ensures that interop fee is being paid in one way or another.
        // Only enforce this requirement when parsing bundle attributes.
        if (
            !attributeUsed[4] &&
            (_restriction == AttributeParsingRestrictions.OnlyBundleAttributes ||
                _restriction == AttributeParsingRestrictions.CallAndBundleAttributes)
        ) {
            revert UseFixedFeeRequired();
        }
    }

    /// @notice Checks if the attribute selector is supported by the InteropCenter.
    /// @param _attributeSelector The attribute selector to check.
    /// @return True if the attribute selector is supported, false otherwise.
    function supportsAttribute(
        bytes4 _attributeSelector
    ) external pure override(IERC7786GatewaySource, IInteropCenter) returns (bool) {
        bytes4[5] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
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
    function _getERC7786AttributeSelectors() internal pure returns (bytes4[5] memory) {
        return [
            IERC7786Attributes.interopCallValue.selector,
            IERC7786Attributes.indirectCall.selector,
            IERC7786Attributes.executionAddress.selector,
            IERC7786Attributes.unbundlerAddress.selector,
            IERC7786Attributes.useFixedFee.selector
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

    /*//////////////////////////////////////////////////////////////
                            Fee Management
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the base token fee per interop call (used when useFixedFee=false).
    /// @dev Can be set to 0 to disable base token fees for users.
    /// @param _fee New fee amount in base token wei.
    /// @dev Only callable via L1 Admin.sol service transaction (chain admin calls Admin.setInteropFee on L1).
    function setInteropFee(uint256 _fee) external onlyServiceTransactionSender {
        uint256 oldFee = interopProtocolFee;
        interopProtocolFee = _fee;
        emit InteropFeeUpdated(oldFee, _fee);
    }
}
