// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {ETH_TOKEN_ADDRESS, SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {EmptyAssetId, Unauthorized} from "../../common/L1ContractErrors.sol";
import {BridgehubBase} from "./BridgehubBase.sol";
import {IL2Bridgehub} from "./IL2Bridgehub.sol";
import {ICTMDeploymentTracker} from "../ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {L1View} from "../../common/l2-helpers/L1View.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2Bridgehub is BridgehubBase, IL2Bridgehub {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @dev The asset ID of ETH token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is a temporary security measure.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice The chain's own side of the peer whitelist, mirrored from L1 by service transactions. Used by
    /// {isPeerAllowed} until the L1 read addresses are set.
    /// @dev Formerly the public `isPeerAllowed` mapping; renamed to free the selector, the slot is unchanged.
    mapping(uint256 chainId => bool) internal mirroredPeerAllowed;

    /// @inheritdoc IL2Bridgehub
    address public l1MessageRoot;

    /// @inheritdoc IL2Bridgehub
    address public l1ChainRegistrationSender;

    modifier onlyChainRegistrationSender() {
        if (
            /// Note on the L2 the chainRegistrationSender is aliased.
            msg.sender != chainRegistrationSender && msg.sender != SERVICE_TRANSACTION_SENDER
        ) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    /// @param _l1ChainId The chain id of L1.
    /// @param _owner The owner of the contract.
    /// @param _maxNumberOfZKChains The maximum number of ZK chains that can be created.
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        uint256 _maxNumberOfZKChains
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        updateL2(_l1ChainId, _owner, _maxNumberOfZKChains);
        _initializeInner();
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2Bridgehub on existing chains during
    /// the upgrade.
    /// @param _l1ChainId The chain id of L1.
    /// @param _owner The expected owner. If the current owner is different (e.g. a temporary
    ///        multisig on a chain that predates decentralized governance), it will be reset.
    /// @param _maxNumberOfZKChains The maximum number of ZK chains that can be created.
    function updateL2(uint256 _l1ChainId, address _owner, uint256 _maxNumberOfZKChains) public onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // Ensure the owner matches the expected governance. Pre-v31 ZKsync OS testnets ran with a
        // temporary multisig owner; we reset it here so every chain ends up with the same
        // (aliased L1 governance) owner after v31.
        if (owner() != _owner) {
            _transferOwnership(_owner);
        }

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones with `onlyL1` modifier.
        // We will change this with interop.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
    }

    /// @inheritdoc IL2Bridgehub
    function allowInteropPeer(uint256 _chainId, bytes32 _baseTokenAssetId) external onlyChainRegistrationSender {
        require(_baseTokenAssetId != bytes32(0), EmptyAssetId());
        baseTokenAssetId[_chainId] = _baseTokenAssetId;
        mirroredPeerAllowed[_chainId] = true;
    }

    /// @inheritdoc IL2Bridgehub
    function deregisterChainForInterop(uint256 _chainId) external onlyChainRegistrationSender {
        delete baseTokenAssetId[_chainId];
        delete mirroredPeerAllowed[_chainId];
    }

    /// @inheritdoc IL2Bridgehub
    /// @dev Proof-of-concept: production would set the addresses in the force deployments.
    function setL1ReadAddresses(address _l1MessageRoot, address _l1ChainRegistrationSender) external onlyOwner {
        l1MessageRoot = _l1MessageRoot;
        l1ChainRegistrationSender = _l1ChainRegistrationSender;
        emit L1ReadAddressesSet(_l1MessageRoot, _l1ChainRegistrationSender);
    }

    /// @inheritdoc IL2Bridgehub
    function isPeerAllowed(uint256 _chainId) external view returns (bool) {
        if (!_readsL1()) {
            return mirroredPeerAllowed[_chainId];
        }
        return _isPeerAllowedOnL1(_chainId, false);
    }

    /// @inheritdoc IL2Bridgehub
    /// @dev Until the L1 read addresses are set, only the chain's own side is known, as in {isPeerAllowed}.
    function canSendTo(uint256 _chainId) external view returns (bool) {
        if (!_readsL1()) {
            return mirroredPeerAllowed[_chainId];
        }
        return _isPeerAllowedOnL1(_chainId, true);
    }

    /// @dev Whether the peer whitelist is read from L1 instead of the mirror.
    function _readsL1() internal view returns (bool) {
        return l1MessageRoot != address(0) && l1ChainRegistrationSender != address(0);
    }

    /// @dev Reads the peer whitelist at the chain's L1SLOAD anchor.
    /// See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _peerChainId The peer.
    /// @param _requirePeerConsent Whether the peer's admin must also have allowed this chain.
    function _isPeerAllowedOnL1(uint256 _peerChainId, bool _requirePeerConsent) internal view returns (bool) {
        if (!L1View.isInteropActive(l1MessageRoot, block.chainid, _peerChainId)) {
            return false;
        }
        if (!L1View.isInteropPeerAllowed(l1ChainRegistrationSender, block.chainid, _peerChainId)) {
            return false;
        }
        return
            !_requirePeerConsent ||
            L1View.isInteropPeerAllowed(l1ChainRegistrationSender, _peerChainId, block.chainid);
    }

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the asset ID of ETH token for internal use.
    function _getEthTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    /// @dev Returns the maximum number of ZK chains for internal use.
    function _getMaxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }

    /// @dev Returns the L1 chain ID for internal use.
    function _getL1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    /// @notice Set addresses
    function setAddresses(
        address _assetRouter,
        ICTMDeploymentTracker _l1CtmDeployer,
        IMessageRootBase _messageRoot,
        address _chainAssetHandler,
        address _chainRegistrationSender
    ) external override onlyOwnerOrUpgrader {
        assetRouter = IAssetRouterBase(_assetRouter);
        l1CtmDeployer = _l1CtmDeployer;
        messageRoot = _messageRoot;
        chainAssetHandler = _chainAssetHandler;
        chainRegistrationSender = _chainRegistrationSender;
    }
}
