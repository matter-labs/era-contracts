// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;


import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
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

import {IERC7786GatewaySource} from "./IERC7786.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The InteropCenter contract serves as the primary entry point for L1<->L2 communication,
/// facilitating interactions between end user and bridges.
contract InteropCenter is IInteropCenter, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @notice The bridgehub, responsible for registering chains.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by this shared Bridge.
    address public assetRouter;

    IAssetTracker public assetTracker;

    /// @notice The number of total sent bundles, used for bundle id generation and uniqueness.
    mapping(address sender => uint256 bundleCount) public bundleCount;

    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAssetRouter() {
        if (msg.sender != assetRouter) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL1() {
        if (L1_CHAIN_ID != block.chainid) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2() {
        if (L1_CHAIN_ID == block.chainid) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2NotToL1(uint256 _destinationChainId) {
        if (_destinationChainId == L1_CHAIN_ID) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlySettlementLayerRelayedSender() {
        /// There is no sender for the wrapping, we use a virtual address.
        if (msg.sender != SETTLEMENT_LAYER_RELAY_SENDER) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice to avoid parity hack
    constructor(IBridgehub _bridgehub, uint256 _l1ChainId, address _owner) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

        _transferOwnership(_owner);
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer onlyL1 {
        _transferOwnership(_owner);
    }

    /// @notice To set the addresses of some of the ecosystem contracts, only Owner. Not done in initialize, as
    /// the order of deployment is InteropCenter, other contracts, and then we call this.
    /// @param _assetRouter the shared bridge address
    function setAddresses(address _assetRouter, address _assetTracker) external onlyOwner {
        assetRouter = _assetRouter;
        assetTracker = IAssetTracker(_assetTracker);
    }


    /*//////////////////////////////////////////////////////////////
                        Bundle interface
    //////////////////////////////////////////////////////////////*/

    function _addCallToBundle(
        InteropBundle memory _interopBundle,
        InteropCallStarter memory _interopCallStarter,
        address _sender, 
        uint256 _index
    ) internal {
        InteropCall memory interopCall = InteropCall({
            shadowAccount: false,
            to: _interopCallStarter.nextContract,
            data: _interopCallStarter.data,
            value: _interopCallStarter.requestedInteropCallValue,
            from: _sender
        });
        _interopBundle.calls[_index] = interopCall;
    }

    function _finishAndSendBundleLong(
        InteropBundle memory _bundle,
        uint256 _bundleCallsTotalValue,
        address _executionAddress,
        uint256 _receivedMsgValue,
        address _sender
    ) internal returns (bytes32 interopBundleHash) {

        _ensureCorrectTotalValue(
            _bundle.destinationChainId,
            _bundleCallsTotalValue,
            _receivedMsgValue
        );

        address[] memory executionAddresses = new address[](1);

        bytes memory interopBundleBytes = abi.encode(_bundle);
        // TODO use canonicalTxHash for linking it to the trigger, instead of interopBundleHash
        bytes32 canonicalTxHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            bytes.concat(BUNDLE_IDENTIFIER, interopBundleBytes)
        );
        emit InteropBundleSent(canonicalTxHash, interopBundleHash, _bundle);
        interopBundleHash = keccak256(interopBundleBytes);
    }

    function _ensureCorrectTotalValue(
        uint256 _destinationChainId,
        uint256 _totalValue,
        uint256 _receivedMsgValue
    ) internal {
        bytes32 tokenAssetId = BRIDGE_HUB.baseTokenAssetId(_destinationChainId);
        if (tokenAssetId == ETH_TOKEN_ASSET_ID || tokenAssetId == bytes32(0)) {
            // kl todo until we sort out chain registration on L2s we assume the same base token.
            if (_receivedMsgValue != _totalValue) {
                revert MsgValueMismatch(_totalValue, _receivedMsgValue);
            }
        } else {
            if (_receivedMsgValue != 0) {
                revert MsgValueMismatch(0, _receivedMsgValue);
            }
        }

        // slither-disable-next-line arbitrary-send-eth
        if (tokenAssetId == BRIDGE_HUB.baseTokenAssetId(block.chainid)) {
            L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue{value: _totalValue}();
        } else {
            IL1AssetRouter(assetRouter).bridgehubDepositBaseToken(
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

    function sendCall(
        uint256 _destinationChainId,
        address _destinationAddress,
        bytes calldata _data,
        uint256 _value
    ) public payable onlyL2NotToL1(_destinationChainId) returns (bytes32) {
        InteropBundle memory bundle = InteropBundle({
            destinationChainId: _destinationChainId,
            sendingBlockNumber: block.number,
            calls: new InteropCall[](1),
            executionAddress: address(0)
        });
        _addCallToBundle(
            bundle,
            InteropCallStarter({nextContract: _destinationAddress, requestedInteropCallValue: _value, data: _data, attributes: new bytes[](0)}),
            msg.sender,
            0
        );
        bytes32 bundleHash = _finishAndSendBundleLong(bundle, _value, address(0), msg.value, msg.sender);
        return bundleHash;
    }

    function sendBundle(
        uint256 _destinationChainId,
        InteropCallStarter[] calldata _callStarters
    ) public payable onlyL2NotToL1(_destinationChainId) returns (bytes32) {
        InteropCallStarterInternal[] memory callStartersInternal = new InteropCallStarterInternal[](
            _callStarters.length
        );
        for (uint256 i = 0; i < _callStarters.length; i++) {
            (bool directCall, uint256 indirectCallMessageValue) = _parseCallStarter(_callStarters[i]);
            callStartersInternal[i] = InteropCallStarterInternal({
                nextContract: _callStarters[i].nextContract,
                data: _callStarters[i].data,
                requestedInteropCallValue: _callStarters[i].requestedInteropCallValue,
                directCall: directCall,
                indirectCallMessageValue: indirectCallMessageValue
            });
        }
        return _sendBundle(_destinationChainId, callStartersInternal, msg.value, address(0), msg.sender);
    }

    function _parseCallStarter(InteropCallStarter calldata _callStarter) internal pure returns (bool, uint256) {
        if (_callStarter.attributes.length == 0) {
            return (true, 0);
        } else if (_callStarter.attributes.length == 1) {
            bytes4 selector = bytes4(_callStarter.attributes[0]);
            require(
                selector == IERC7786Attributes.indirectCall.selector,
                IERC7786GatewaySource.UnsupportedAttribute(selector)
            );
            uint256 indirectCallMessageValue;
            (, indirectCallMessageValue) = AttributesDecoder.decodeIndirectCall(_callStarter.attributes[0]);

            return (false, indirectCallMessageValue);
        } else {
            revert IERC7786GatewaySource.UnsupportedAttribute(bytes4(0));
        }
    }

    function _sendBundle(
        uint256 _destinationChainId,
        InteropCallStarterInternal[] memory _callStarters,
        uint256 _msgValue,
        address _executionAddress,
        address _sender
    ) internal returns (bytes32) {
        uint256 feeValue;
        InteropBundle memory bundle = InteropBundle({
            destinationChainId: _destinationChainId,
            sendingBlockNumber: block.number,
            calls: new InteropCall[](_callStarters.length),
            executionAddress: address(0)
        });
        for (uint256 i = 0; i < _callStarters.length; i++) {
            InteropCallStarterInternal memory callStarter = _callStarters[i];
            InteropCallStarter memory actualCallStarter;
            if (!callStarter.directCall) {
                // console.log("fee indirect call");
                actualCallStarter = IL2AssetRouter(callStarter.nextContract).interopCenterInitiateBridge{
                    value: callStarter.indirectCallMessageValue
                }(_destinationChainId, _sender, callStarter.requestedInteropCallValue, callStarter.data);
            } else {
                // console.log("fee direct call");
                actualCallStarter = InteropCallStarter({
                    nextContract: callStarter.nextContract,
                    data: callStarter.data,
                    requestedInteropCallValue: callStarter.requestedInteropCallValue,
                    attributes: new bytes[](0)
                });
            }
            _addCallToBundle(bundle, actualCallStarter, _sender, i);
            feeValue += callStarter.requestedInteropCallValue;
        }
        bytes32 bundleHash = _finishAndSendBundleLong(bundle, feeValue, _executionAddress, _msgValue, _sender);
        return bundleHash;
    }

    /*//////////////////////////////////////////////////////////////
                            GW function
    //////////////////////////////////////////////////////////////*/

    /// @notice Used to forward a transaction on the gateway to the chains mailbox (from L1).
    /// @param _chainId the chainId of the chain
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp for the transaction
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

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
