// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";

import {IChainRegistrationSender} from "./IChainRegistrationSender.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../message-root/IL1MessageRoot.sol";
import {IMessageRootBase} from "../message-root/IMessageRoot.sol";
import {IProxyUpgradeInitializable} from "../../upgrades/registry/IUpgradeInit.sol";

import {ERC1967_ADMIN_SLOT} from "../../common/Config.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {
    ChainHasNoBatchesInMessageRoot,
    InteropAlreadySuspended,
    InteropNotEnabled,
    InteropNotSuspended,
    InteropPeerAlreadyAllowed,
    InvalidInteropPeer,
    ZKChainNotRegistered
} from "../bridgehub/L1BridgehubErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Holds the interop gating state that chains read from L1 with L1SLOAD: the peer whitelist the chain admins
/// write, the peers' base tokens and the owner's suspensions. See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
contract ChainRegistrationSender is
    IChainRegistrationSender,
    IProxyUpgradeInitializable,
    ReentrancyGuard,
    Ownable2StepUpgradeable
{
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @dev Written by the retired consent-free registration and read by nothing.
    mapping(uint256 chainToBeRegistered => mapping(uint256 chainRegisteredOn => bool isRegistered))
        internal __DEPRECATED_chainRegisteredOnChain;

    /// @inheritdoc IChainRegistrationSender
    /// @dev Read from L2 with L1SLOAD: its slot must stay `CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT`.
    mapping(uint256 chainId => mapping(uint256 peerChainId => bool allowed)) public interopPeerAllowed;

    /// @notice Whether the owner suspended interop for the chain.
    /// @dev Read from L2 with L1SLOAD: its slot must stay `CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT`.
    mapping(uint256 chainId => bool suspended) internal interopSuspended;

    /// @inheritdoc IChainRegistrationSender
    /// @dev Read from L2 with L1SLOAD: its slot must stay `CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT`.
    mapping(uint256 chainId => bytes32 baseTokenAssetId) public interopBaseTokenAssetId;

    /// @dev Contract is expected to be used as proxy implementation on L1.
    /// @notice to avoid parity hack
    constructor(IBridgehubBase _bridgehub) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
    }

    /// @notice Used to initialize the contract.
    /// @dev Also deployed on L2 as a system contract; there the owner and related functions are unused.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @inheritdoc IProxyUpgradeInitializable
    /// @dev The v36 snapshot backfill, see {protocol-docs/l1sload.md#upgrade-from-v35}. Only the proxy admin, i.e.
    /// through `upgradeToAndCall`.
    function initializeUpgrade() external reinitializer(2) {
        require(msg.sender == StorageSlot.getAddressSlot(ERC1967_ADMIN_SLOT).value, Unauthorized(msg.sender));
        IMessageRootBase messageRoot = BRIDGE_HUB.messageRoot();
        uint256[] memory chainIds = BRIDGE_HUB.getAllZKChainChainIDs();
        uint256 chainIdsLength = chainIds.length;
        for (uint256 i = 0; i < chainIdsLength; ++i) {
            uint256 chainId = chainIds[i];
            if (
                interopBaseTokenAssetId[chainId] != bytes32(0) ||
                !IL1MessageRoot(address(messageRoot)).isInteropEnabled(chainId) ||
                messageRoot.chainTreeLeafCount(chainId) == 0
            ) {
                continue;
            }
            interopBaseTokenAssetId[chainId] = BRIDGE_HUB.baseTokenAssetId(chainId);
        }
    }

    /// @inheritdoc IChainRegistrationSender
    function allowInteropPeer(uint256 _chainId, uint256 _peerChainId) external nonReentrant {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
        require(msg.sender == IGetters(zkChain).getAdmin(), Unauthorized(msg.sender));
        _checkPeerPair(_chainId, _peerChainId);
        require(BRIDGE_HUB.getZKChain(_peerChainId) != address(0), ZKChainNotRegistered());
        require(!interopPeerAllowed[_chainId][_peerChainId], InteropPeerAlreadyAllowed(_chainId, _peerChainId));
        IMessageRootBase messageRoot = BRIDGE_HUB.messageRoot();
        require(IL1MessageRoot(address(messageRoot)).isInteropEnabled(_chainId), InteropNotEnabled(_chainId));
        require(IL1MessageRoot(address(messageRoot)).isInteropEnabled(_peerChainId), InteropNotEnabled(_peerChainId));
        // See {protocol-docs/l1sload.md#the-base-token-snapshot}.
        bytes32 peerBaseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_peerChainId);
        require(peerBaseTokenAssetId != bytes32(0), ZKChainNotRegistered());
        require(messageRoot.chainTreeLeafCount(_peerChainId) != 0, ChainHasNoBatchesInMessageRoot(_peerChainId));

        interopPeerAllowed[_chainId][_peerChainId] = true;
        interopBaseTokenAssetId[_peerChainId] = peerBaseTokenAssetId;
        emit InteropPeerAllowed(_chainId, _peerChainId);
    }

    /// @inheritdoc IChainRegistrationSender
    function deregisterInteropPairs(
        uint256 _chainRegisteredOn,
        uint256[] calldata _chainsToDeregister
    ) external nonReentrant {
        address zkChain = BRIDGE_HUB.getZKChain(_chainRegisteredOn);
        require(zkChain != address(0), ZKChainNotRegistered());
        require(msg.sender == owner() || msg.sender == IGetters(zkChain).getAdmin(), Unauthorized(msg.sender));
        uint256 chainsLength = _chainsToDeregister.length;
        for (uint256 i = 0; i < chainsLength; ++i) {
            uint256 chainToDeregister = _chainsToDeregister[i];
            _checkPeerPair(_chainRegisteredOn, chainToDeregister);

            delete interopPeerAllowed[_chainRegisteredOn][chainToDeregister];
            emit InteropPairDeregistered(_chainRegisteredOn, chainToDeregister);
        }
    }

    /// @inheritdoc IChainRegistrationSender
    function suspendInterop(uint256 _chainId) external onlyOwner {
        require(!interopSuspended[_chainId], InteropAlreadySuspended(_chainId));
        interopSuspended[_chainId] = true;
        emit InteropSuspended(_chainId);
    }

    /// @inheritdoc IChainRegistrationSender
    function resumeInterop(uint256 _chainId) external onlyOwner {
        require(interopSuspended[_chainId], InteropNotSuspended(_chainId));
        interopSuspended[_chainId] = false;
        emit InteropResumed(_chainId);
    }

    /// @inheritdoc IChainRegistrationSender
    function isInteropSuspended(uint256 _chainId) external view returns (bool) {
        return interopSuspended[_chainId];
    }

    /// @notice Rejects pairs that are never interop peers: the chain itself, L1, and a chain settling on the chain.
    /// @param _chainId The chain whose whitelist is written.
    /// @param _peerChainId The peer.
    function _checkPeerPair(uint256 _chainId, uint256 _peerChainId) internal view {
        if (
            _peerChainId == _chainId ||
            _peerChainId == block.chainid ||
            BRIDGE_HUB.settlementLayer(_peerChainId) == _chainId
        ) {
            revert InvalidInteropPeer(_chainId, _peerChainId);
        }
    }
}
