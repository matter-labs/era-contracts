// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {IChainRegistrationSender} from "./IChainRegistrationSender.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IL1CrossChainSender} from "../../bridge/interfaces/IL1CrossChainSender.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "../bridgehub/IBridgehubBase.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../message-root/IL1MessageRoot.sol";

import {L2_BRIDGEHUB_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";

import {Unauthorized, UnsupportedEncodingVersion} from "../../common/L1ContractErrors.sol";
import {
    ChainHasNoBatchesInMessageRoot,
    InteropNotEnabled,
    InteropPeerAlreadyAllowed,
    InteropPeerNotAllowed,
    InvalidInteropPeer,
    NoEthAllowed,
    ZKChainNotRegistered
} from "../bridgehub/L1BridgehubErrors.sol";
import {ChainFeature, IL2Bridgehub} from "../bridgehub/IL2Bridgehub.sol";

/// @dev The encoding version of `bridgehubDeposit` data that re-sends the registration of an allowed pair.
/// The retired version `0x01` registered any pair without consent.
bytes1 constant CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION = 0x02;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Registers chains on other chains' L2 Bridgehubs to enable interop between them, for the pairs
/// the chain admins whitelisted. See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
contract ChainRegistrationSender is
    IChainRegistrationSender,
    IL1CrossChainSender,
    ReentrancyGuard,
    Ownable2StepUpgradeable
{
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @dev Written by the retired consent-free registration and read by nothing.
    mapping(uint256 chainToBeRegistered => mapping(uint256 chainRegisteredOn => bool isRegistered))
        internal __DEPRECATED_chainRegisteredOnChain;

    /// @inheritdoc IChainRegistrationSender
    mapping(uint256 chainId => mapping(uint256 peerChainId => bool allowed)) public interopPeerAllowed;

    /// @inheritdoc IChainRegistrationSender
    mapping(uint256 chainId => mapping(ChainFeature feature => bool enabled)) public isChainFeatureEnabled;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

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

    /// @inheritdoc IChainRegistrationSender
    function allowInteropPeer(uint256 _chainId, uint256 _peerChainId) external nonReentrant {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
        require(msg.sender == IGetters(zkChain).getAdmin(), Unauthorized(msg.sender));
        _checkPeerPair(_chainId, _peerChainId);
        require(BRIDGE_HUB.getZKChain(_peerChainId) != address(0), ZKChainNotRegistered());
        require(!interopPeerAllowed[_chainId][_peerChainId], InteropPeerAlreadyAllowed(_chainId, _peerChainId));
        IL1MessageRoot messageRoot = IL1MessageRoot(address(BRIDGE_HUB.messageRoot()));
        require(messageRoot.isInteropEnabled(_chainId), InteropNotEnabled(_chainId));
        require(messageRoot.isInteropEnabled(_peerChainId), InteropNotEnabled(_peerChainId));

        interopPeerAllowed[_chainId][_peerChainId] = true;
        emit InteropPeerAllowed(_chainId, _peerChainId);

        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(L2_BRIDGEHUB_ADDR, _getL2RegistrationCalldata(_peerChainId));
    }

    /// @inheritdoc IChainRegistrationSender
    function setChainFeatureEnabled(uint256 _chainId, ChainFeature _feature, bool _enabled) external nonReentrant {
        require(msg.sender == owner() || msg.sender == BRIDGE_HUB.admin(), Unauthorized(msg.sender));
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());

        isChainFeatureEnabled[_chainId][_feature] = _enabled;
        emit ChainFeatureSet(_chainId, _feature, _enabled);

        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IL2Bridgehub.setChainFeatureEnabled, (_feature, _enabled))
        );
    }

    /// @inheritdoc IChainRegistrationSender
    // The call to the ZK chain precedes the next pair's write; the function is `nonReentrant`.
    // slither-disable-next-line reentrancy-no-eth
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
            // slither-disable-next-line unused-return
            IMailbox(zkChain).requestL2ServiceTransaction(
                L2_BRIDGEHUB_ADDR,
                abi.encodeCall(IL2Bridgehub.deregisterChainForInterop, (chainToDeregister))
            );
        }
    }

    /// @inheritdoc IL1CrossChainSender
    /// @dev Re-sends the registration of an allowed pair via a normal deposit: anyone can trigger it
    /// (via the Bridgehub), but the caller provides the base tokens.
    // slither-disable-next-line locked-ether
    function bridgehubDeposit(
        uint256 _chainRegisteredOn,
        address,
        uint256,
        bytes calldata _data
    ) external payable virtual override onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
        if (msg.value != 0) {
            revert NoEthAllowed();
        }
        bytes1 encodingVersion = _data[0];
        if (encodingVersion != CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION) {
            revert UnsupportedEncodingVersion();
        }

        uint256 peerChainId = abi.decode(_data[1:], (uint256));
        require(
            interopPeerAllowed[_chainRegisteredOn][peerChainId],
            InteropPeerNotAllowed(_chainRegisteredOn, peerChainId)
        );

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_BRIDGEHUB_ADDR,
            l2Calldata: _getL2RegistrationCalldata(peerChainId),
            factoryDeps: new bytes[](0),
            // `txDataHash` exists so token bridges can recover funds after a failed L2 leg; nothing
            // to recover here, so `bytes32(0)` is fine.
            txDataHash: bytes32(0)
        });
    }

    /// @notice Returns the L2 Bridgehub calldata allowing interop with `_peerChainId`.
    /// @dev Also enforces the atomic-interop timeout precondition: the peer must already have at least
    /// one batch inside this layer's message root. See {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}.
    /// @param _peerChainId The chain to register.
    function _getL2RegistrationCalldata(uint256 _peerChainId) internal view returns (bytes memory) {
        bytes32 baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_peerChainId);
        if (baseTokenAssetId == bytes32(0)) {
            revert ZKChainNotRegistered();
        }
        if (BRIDGE_HUB.messageRoot().chainTreeLeafCount(_peerChainId) == 0) {
            revert ChainHasNoBatchesInMessageRoot(_peerChainId);
        }
        return abi.encodeCall(IL2Bridgehub.allowInteropPeer, (_peerChainId, baseTokenAssetId));
    }

    /// @notice Rejects pairs whose L2 Bridgehub entry must never change: the chain itself, L1, and a chain
    /// settling on the chain, which the chain's L2 Bridgehub registered as a settlement layer.
    /// @param _chainId The chain whose L2 Bridgehub is written.
    /// @param _peerChainId The chain whose entry is written.
    function _checkPeerPair(uint256 _chainId, uint256 _peerChainId) internal view {
        if (
            _peerChainId == _chainId ||
            _peerChainId == block.chainid ||
            BRIDGE_HUB.settlementLayer(_peerChainId) == _chainId
        ) {
            revert InvalidInteropPeer(_chainId, _peerChainId);
        }
    }

    /// @inheritdoc IL1CrossChainSender
    /// @dev No-op: failed L1->L2 transactions need no recovery here.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external override {}
}
