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

import {L2_BRIDGEHUB_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INTEROP_ROOT_WRITERS_FEATURE, TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";
import {SEMVER_MINOR_OFFSET} from "../../common/libraries/SemVer.sol";

import {Unauthorized, UnsupportedEncodingVersion} from "../../common/L1ContractErrors.sol";
import {
    ChainFeaturesNotSupported,
    ChainHasNoBatchesInMessageRoot,
    InteropNotEnabled,
    InteropPeerAlreadyAllowed,
    InteropPeerNotAllowed,
    InvalidInteropPeer,
    NoEthAllowed,
    ZKChainNotRegistered
} from "../bridgehub/L1BridgehubErrors.sol";
import {IL2Bridgehub} from "../bridgehub/IL2Bridgehub.sol";
import {IL2InteropRootStorage} from "../../interop/IL2InteropRootStorage.sol";
import {
    InteropRootSourceAlreadyAssigned,
    InteropRootSourceInUse,
    InteropRootSourceNotAssigned,
    InteropRootWritersNotEnabled,
    InteropRootWritersNotSupported,
    InvalidInteropRootSource
} from "../../interop/InteropErrors.sol";

/// @dev The encoding version of `bridgehubDeposit` data that re-sends the registration of an allowed pair.
/// The retired version `0x01` registered any pair without consent.
bytes1 constant CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION = 0x02;

/// @dev The first protocol version, v0.36.0, whose `L2Bridgehub` has `setChainFeatureEnabled`.
uint256 constant CHAIN_FEATURES_MIN_PROTOCOL_VERSION = 36 << SEMVER_MINOR_OFFSET;

/// @dev The first protocol version, v0.36.0, whose `L2InteropRootStorage` has the interop root writers.
uint256 constant INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION = 36 << SEMVER_MINOR_OFFSET;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Registers chains on other chains' L2 Bridgehubs to enable interop between them, for the pairs
/// the chain admins whitelisted, pushes each chain's features to its own L2 Bridgehub and its interop root writers to
/// its own `L2InteropRootStorage`. See {protocol-docs/interop-gating.md#interop-peer-whitelist},
/// {protocol-docs/interop-gating.md#chain-features} and {protocol-docs/interop.md#interop-root-writers}.
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
    mapping(uint256 chainId => mapping(bytes32 feature => bool enabled)) public isChainFeatureEnabled;

    /// @inheritdoc IChainRegistrationSender
    mapping(uint256 chainId => mapping(uint256 sourceChainId => address writer)) public interopRootWriter;

    /// @inheritdoc IChainRegistrationSender
    mapping(uint256 sourceChainId => uint256 chainId) public interopRootSourceChain;

    /// @inheritdoc IChainRegistrationSender
    mapping(uint256 sourceChainId => bool used) public isInteropRootSourceUsed;

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
    function setChainFeatureEnabled(uint256 _chainId, bytes32 _feature, bool _enabled) external nonReentrant {
        _requireGovernance();
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
        // The chain's L2 runs its upgrade transaction before this service transaction, so a chain that
        // reports the version already has the setter on L2.
        uint256 protocolVersion = IGetters(zkChain).getProtocolVersion();
        require(
            protocolVersion >= CHAIN_FEATURES_MIN_PROTOCOL_VERSION,
            ChainFeaturesNotSupported(_chainId, protocolVersion)
        );

        isChainFeatureEnabled[_chainId][_feature] = _enabled;
        emit ChainFeatureSet(_chainId, _feature, _enabled);

        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IL2Bridgehub.setChainFeatureEnabled, (_feature, _enabled))
        );
    }

    /// @inheritdoc IChainRegistrationSender
    function setInteropRootWriter(uint256 _chainId, uint256 _sourceChainId, address _writer) external nonReentrant {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
        address chainAdmin = IGetters(zkChain).getAdmin();
        if (_writer != address(0)) {
            require(msg.sender == chainAdmin, Unauthorized(msg.sender));
            _useInteropRootSource(_chainId, _sourceChainId);
        } else {
            _requireChainAdminOrGovernance(chainAdmin);
        }
        // The chain's L2 runs its upgrade transaction before this service transaction, so a chain that reports the
        // version already has the setter on L2. Setting a writer needs the chain feature, which implies the version;
        // removing one does not, so the version is checked here for both. A writer can't exist on an older chain, so
        // this refuses no removal that would matter.
        uint256 protocolVersion = IGetters(zkChain).getProtocolVersion();
        require(
            protocolVersion >= INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION,
            InteropRootWritersNotSupported(_chainId, protocolVersion)
        );

        interopRootWriter[_chainId][_sourceChainId] = _writer;
        emit InteropRootWriterSet(_chainId, _sourceChainId, _writer);

        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(
            L2_INTEROP_ROOT_STORAGE_ADDR,
            abi.encodeCall(IL2InteropRootStorage.setInteropRootWriter, (_sourceChainId, _writer))
        );
    }

    /// @inheritdoc IChainRegistrationSender
    function assignInteropRootSource(uint256 _sourceChainId, uint256 _chainId) external {
        _requireGovernance();
        require(BRIDGE_HUB.getZKChain(_chainId) != address(0), ZKChainNotRegistered());
        // The roots of L1 and of every ZK chain reach a chain through its settlement layer, never through a writer.
        // The Bridgehub registers no chain under an assigned source id afterwards.
        require(
            _sourceChainId != block.chainid && BRIDGE_HUB.getZKChain(_sourceChainId) == address(0),
            InvalidInteropRootSource(_sourceChainId)
        );
        uint256 assignedTo = interopRootSourceChain[_sourceChainId];
        require(assignedTo == 0, InteropRootSourceAlreadyAssigned(_sourceChainId, assignedTo));

        interopRootSourceChain[_sourceChainId] = _chainId;
        emit InteropRootSourceAssigned(_sourceChainId, _chainId);
    }

    /// @inheritdoc IChainRegistrationSender
    function releaseInteropRootSource(uint256 _sourceChainId) external {
        _requireGovernance();
        uint256 assignedTo = interopRootSourceChain[_sourceChainId];
        require(!isInteropRootSourceUsed[_sourceChainId], InteropRootSourceInUse(_sourceChainId, assignedTo));
        delete interopRootSourceChain[_sourceChainId];
        emit InteropRootSourceReleased(_sourceChainId, assignedTo);
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

    /// @dev Only the owner and the Bridgehub admin decide what the ecosystem as a whole depends on.
    function _requireGovernance() internal view {
        require(msg.sender == owner() || msg.sender == BRIDGE_HUB.admin(), Unauthorized(msg.sender));
    }

    /// @dev Removals are also open to the owner and to the Bridgehub admin.
    function _requireChainAdminOrGovernance(address _chainAdmin) internal view {
        require(
            msg.sender == _chainAdmin || msg.sender == owner() || msg.sender == BRIDGE_HUB.admin(),
            Unauthorized(msg.sender)
        );
    }

    /// @dev Checks that `_chainId` may have a writer for `_sourceChainId`, and makes the source's assignment to it
    /// permanent. See {protocol-docs/interop.md#interop-root-writers}.
    function _useInteropRootSource(uint256 _chainId, uint256 _sourceChainId) internal {
        require(isChainFeatureEnabled[_chainId][INTEROP_ROOT_WRITERS_FEATURE], InteropRootWritersNotEnabled());
        require(
            interopRootSourceChain[_sourceChainId] == _chainId,
            InteropRootSourceNotAssigned(_chainId, _sourceChainId)
        );
        if (!isInteropRootSourceUsed[_sourceChainId]) {
            isInteropRootSourceUsed[_sourceChainId] = true;
            emit InteropRootSourceUsed(_sourceChainId, _chainId);
        }
    }

    /// @inheritdoc IL1CrossChainSender
    /// @dev No-op: failed L1->L2 transactions need no recovery here.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external override {}
}
