// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {
    CHAIN_FEATURES_MIN_PROTOCOL_VERSION,
    CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION,
    ChainRegistrationSender,
    INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION,
    INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION
} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IChainRegistrationSender} from "contracts/core/chain-registration/IChainRegistrationSender.sol";
import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {L2_BRIDGEHUB_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    INTEROP_ROOT_WRITERS_FEATURE,
    L1_TO_L2_INTEROP_FEATURE,
    TWO_BRIDGES_MAGIC_VALUE
} from "contracts/common/Config.sol";
import {InteropCounterparts} from "contracts/common/Messaging.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {
    ChainFeatureNotEnabled,
    InteropCounterpartsNotSupported,
    InteropRootSourceAlreadyAssigned,
    InteropRootSourceInUse,
    InteropRootSourceNotAssigned,
    InteropRootWriterNotSet,
    InteropRootWritersNotEnabled,
    InteropRootWritersNotSupported,
    InvalidInteropCounterparts,
    InvalidInteropRootSource
} from "contracts/interop/InteropErrors.sol";
import {Unauthorized, UnsupportedEncodingVersion, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {
    ChainFeaturesNotSupported,
    ChainHasNoBatchesInMessageRoot,
    InteropNotEnabled,
    InteropPeerAlreadyAllowed,
    InteropPeerNotAllowed,
    InvalidInteropPeer,
    NoEthAllowed,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @notice `ChainRegistrationSender` alone. The Bridgehub, the message root and the chains are mocked to
/// isolate the sender's checks; the end-to-end flow with real contracts is in the integration test
/// `ChainRegistrationSender.t.sol`. See {protocol-docs/interop-gating.md#interop-peer-whitelist} and
/// {protocol-docs/interop-gating.md#chain-features}.
contract ChainRegistrationSenderUnitTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant PEER_CHAIN_ID = 272;
    uint256 internal constant THIRD_CHAIN_ID = 273;
    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;
    bytes32 internal constant PEER_BASE_TOKEN_ASSET_ID = keccak256("peerBaseToken");
    bytes32 internal constant CHAIN_BASE_TOKEN_ASSET_ID = keccak256("chainBaseToken");
    /// @dev A feature nothing reads; the gate takes any id.
    bytes32 internal constant TEST_FEATURE = keccak256("testFeature");

    address internal bridgehub;
    address internal messageRoot;
    address internal owner;
    address internal chain;
    address internal peer;
    address internal chainAdmin;
    ChainRegistrationSender internal sender;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        messageRoot = makeAddr("messageRoot");
        owner = makeAddr("owner");
        chain = makeAddr("chain");
        peer = makeAddr("peer");
        chainAdmin = makeAddr("chainAdmin");

        sender = ChainRegistrationSender(
            address(
                new TransparentUpgradeableProxy(
                    address(new ChainRegistrationSender(IBridgehubBase(bridgehub))),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(ChainRegistrationSender.initialize, (owner))
                )
            )
        );

        // Two registered chains that settle on L1, have interop and a batch in the message root;
        // each test breaks one condition.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(messageRoot));
        _mockChain(CHAIN_ID, chain, CHAIN_BASE_TOKEN_ASSET_ID);
        _mockChain(PEER_CHAIN_ID, peer, PEER_BASE_TOKEN_ASSET_ID);
        vm.mockCall(chain, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(chainAdmin));
        vm.mockCall(peer, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(makeAddr("peerAdmin")));
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.getZKChain, (UNREGISTERED_CHAIN_ID)),
            abi.encode(address(0))
        );
        _mockSettlementLayer(UNREGISTERED_CHAIN_ID, 0);
    }

    function test_initialize_setsOwner() public view {
        assertEq(sender.owner(), owner);
        assertEq(address(sender.BRIDGE_HUB()), bridgehub);
    }

    /*//////////////////////////////////////////////////////////////
                            allowInteropPeer
    //////////////////////////////////////////////////////////////*/

    function test_allowInteropPeer() public {
        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPeerAllowed(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectCall(
            chain,
            abi.encodeCall(IMailbox.requestL2ServiceTransaction, (L2_BRIDGEHUB_ADDR, _registrationCalldata()))
        );
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertFalse(sender.interopPeerAllowed(PEER_CHAIN_ID, CHAIN_ID), "the peer's side needs its own admin");
    }

    function test_allowInteropPeer_revertWhen_alreadyAllowed() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropPeerAlreadyAllowed.selector, CHAIN_ID, PEER_CHAIN_ID));
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.allowInteropPeer(UNREGISTERED_CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_notChainAdmin() public {
        address peerAdmin = makeAddr("peerAdmin");
        vm.prank(peerAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, peerAdmin));
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_peerIsSelf() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, CHAIN_ID, CHAIN_ID));
        sender.allowInteropPeer(CHAIN_ID, CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_peerIsL1() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, CHAIN_ID, block.chainid));
        sender.allowInteropPeer(CHAIN_ID, block.chainid);
    }

    function test_allowInteropPeer_revertWhen_peerNotRegistered() public {
        vm.prank(chainAdmin);
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.allowInteropPeer(CHAIN_ID, UNREGISTERED_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_chainNotEnabled() public {
        _mockInteropEnabled(CHAIN_ID, false);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, CHAIN_ID));
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_peerNotEnabled() public {
        _mockInteropEnabled(PEER_CHAIN_ID, false);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, PEER_CHAIN_ID));
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_peerHasNoBatchesInMessageRoot() public {
        vm.mockCall(
            messageRoot,
            abi.encodeCall(IMessageRootBase.chainTreeLeafCount, (PEER_CHAIN_ID)),
            abi.encode(uint256(0))
        );

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainHasNoBatchesInMessageRoot.selector, PEER_CHAIN_ID));
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    /// @notice A chain whose base token is gone counts as unregistered.
    function test_allowInteropPeer_revertWhen_peerHasNoBaseToken() public {
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (PEER_CHAIN_ID)),
            abi.encode(bytes32(0))
        );

        vm.prank(chainAdmin);
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                            deregisterInteropPairs
    //////////////////////////////////////////////////////////////*/

    /// @notice A pair registered by the retired `registerChain`, which L1 never recorded.
    function test_deregisterInteropPairs_legacyPair() public {
        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectCall(
            chain,
            abi.encodeCall(IMailbox.requestL2ServiceTransaction, (L2_BRIDGEHUB_ADDR, _deregistrationCalldata()))
        );
        vm.prank(owner);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    function test_deregisterInteropPairs_allowedPair() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectCall(
            chain,
            abi.encodeCall(IMailbox.requestL2ServiceTransaction, (L2_BRIDGEHUB_ADDR, _deregistrationCalldata()))
        );
        vm.prank(owner);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID), "cleared on L1");
        vm.prank(bridgehub);
        vm.expectRevert(abi.encodeWithSelector(InteropPeerNotAllowed.selector, CHAIN_ID, PEER_CHAIN_ID));
        sender.bridgehubDeposit(CHAIN_ID, makeAddr("resubmitter"), 0, _resubmissionData(PEER_CHAIN_ID));

        // The admin can allow the pair again.
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID), "allowed again");
    }

    /// @notice The chain's admin can remove its chain's pairs; it answers for their unfinalized flows.
    function test_deregisterInteropPairs_byChainAdmin() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectCall(
            chain,
            abi.encodeCall(IMailbox.requestL2ServiceTransaction, (L2_BRIDGEHUB_ADDR, _deregistrationCalldata()))
        );
        vm.prank(chainAdmin);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @notice One call removes several peers of the chain, reading the chain's admin once.
    function test_deregisterInteropPairs_severalPeers() public {
        _mockChain(THIRD_CHAIN_ID, makeAddr("third"), keccak256("thirdBaseToken"));
        vm.startPrank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        sender.allowInteropPeer(CHAIN_ID, THIRD_CHAIN_ID);
        vm.stopPrank();
        uint256[] memory peers = new uint256[](2);
        (peers[0], peers[1]) = (PEER_CHAIN_ID, THIRD_CHAIN_ID);

        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, THIRD_CHAIN_ID);
        vm.expectCall(
            chain,
            abi.encodeCall(IMailbox.requestL2ServiceTransaction, (L2_BRIDGEHUB_ADDR, _deregistrationCalldata()))
        );
        vm.expectCall(
            chain,
            abi.encodeCall(
                IMailbox.requestL2ServiceTransaction,
                (L2_BRIDGEHUB_ADDR, abi.encodeCall(IL2Bridgehub.deregisterChainForInterop, (THIRD_CHAIN_ID)))
            )
        );
        vm.expectCall(chain, abi.encodeCall(IGetters.getAdmin, ()), 1);
        vm.prank(chainAdmin);
        sender.deregisterInteropPairs(CHAIN_ID, peers);

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertFalse(sender.interopPeerAllowed(CHAIN_ID, THIRD_CHAIN_ID));
    }

    function testFuzz_deregisterInteropPairs_revertWhen_notOwnerNorChainAdmin(address _caller) public {
        // The proxy admin can only reach the proxy itself.
        vm.assume(_caller != owner && _caller != chainAdmin && _caller != makeAddr("proxyAdmin"));
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @notice The admin of the peer cannot remove the chain's side of the pair.
    function test_deregisterInteropPairs_revertWhen_peerAdmin() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        address peerAdmin = makeAddr("peerAdmin");

        vm.prank(peerAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, peerAdmin));
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @notice A list with one invalid peer reverts as a whole, the valid peers included.
    function test_deregisterInteropPairs_revertWhen_oneOfThePeersIsInvalid() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        uint256[] memory peers = new uint256[](2);
        (peers[0], peers[1]) = (PEER_CHAIN_ID, CHAIN_ID);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, CHAIN_ID, CHAIN_ID));
        sender.deregisterInteropPairs(CHAIN_ID, peers);

        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    function test_deregisterInteropPairs_revertWhen_pairIsSelf() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, CHAIN_ID, CHAIN_ID));
        sender.deregisterInteropPairs(CHAIN_ID, _peers(CHAIN_ID));
    }

    /// @notice The L2 Bridgehub of a settlement layer keeps the entries of the chains that settle on it.
    function test_deregisterInteropPairs_revertWhen_peerSettlesOnTheChain() public {
        _mockSettlementLayer(PEER_CHAIN_ID, CHAIN_ID);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, CHAIN_ID, PEER_CHAIN_ID));
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));
    }

    function test_deregisterInteropPairs_revertWhen_chainNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.deregisterInteropPairs(UNREGISTERED_CHAIN_ID, _peers(CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                        bridgehubDeposit (resubmission)
    //////////////////////////////////////////////////////////////*/

    function test_bridgehubDeposit_resubmitsAllowedPair() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.prank(bridgehub);
        L2TransactionRequestTwoBridgesInner memory request = sender.bridgehubDeposit(
            CHAIN_ID,
            makeAddr("resubmitter"),
            0,
            _resubmissionData(PEER_CHAIN_ID)
        );

        assertEq(request.magicValue, TWO_BRIDGES_MAGIC_VALUE);
        assertEq(request.l2Contract, L2_BRIDGEHUB_ADDR);
        assertEq(request.l2Calldata, _registrationCalldata());
        assertEq(request.factoryDeps.length, 0);
        assertEq(request.txDataHash, bytes32(0));
    }

    function test_bridgehubDeposit_revertWhen_pairNotAllowed() public {
        vm.prank(bridgehub);
        vm.expectRevert(abi.encodeWithSelector(InteropPeerNotAllowed.selector, CHAIN_ID, PEER_CHAIN_ID));
        sender.bridgehubDeposit(CHAIN_ID, makeAddr("resubmitter"), 0, _resubmissionData(PEER_CHAIN_ID));
    }

    function test_bridgehubDeposit_revertWhen_legacyEncodingVersion() public {
        vm.prank(bridgehub);
        vm.expectRevert(UnsupportedEncodingVersion.selector);
        sender.bridgehubDeposit(
            CHAIN_ID,
            makeAddr("resubmitter"),
            0,
            bytes.concat(bytes1(0x01), abi.encode(PEER_CHAIN_ID))
        );
    }

    function test_bridgehubDeposit_revertWhen_value() public {
        vm.deal(bridgehub, 1);
        vm.prank(bridgehub);
        vm.expectRevert(NoEthAllowed.selector);
        sender.bridgehubDeposit{value: 1}(CHAIN_ID, makeAddr("resubmitter"), 0, _resubmissionData(PEER_CHAIN_ID));
    }

    function test_bridgehubDeposit_revertWhen_notBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");
        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notBridgehub));
        sender.bridgehubDeposit(CHAIN_ID, notBridgehub, 0, _resubmissionData(PEER_CHAIN_ID));
    }

    /// @notice Failed resubmissions need no recovery.
    function test_bridgehubConfirmL2Transaction_noop() public {
        vm.recordLogs();
        sender.bridgehubConfirmL2Transaction(CHAIN_ID, bytes32(0), bytes32(0));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    function _mockChain(uint256 _chainId, address _chain, bytes32 _baseTokenAssetId) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (_chainId)), abi.encode(_chain));
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (_chainId)),
            abi.encode(_baseTokenAssetId)
        );
        _mockSettlementLayer(_chainId, block.chainid);
        _mockInteropEnabled(_chainId, true);
        vm.mockCall(messageRoot, abi.encodeCall(IMessageRootBase.chainTreeLeafCount, (_chainId)), abi.encode(1));
        vm.mockCall(
            _chain,
            abi.encodeWithSelector(IMailbox.requestL2ServiceTransaction.selector),
            abi.encode(bytes32(0))
        );
    }

    function _mockSettlementLayer(uint256 _chainId, uint256 _settlementLayer) internal {
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.settlementLayer, (_chainId)),
            abi.encode(_settlementLayer)
        );
    }

    function _mockInteropEnabled(uint256 _chainId, bool _enabled) internal {
        vm.mockCall(messageRoot, abi.encodeCall(IL1MessageRoot.isInteropEnabled, (_chainId)), abi.encode(_enabled));
    }

    function _registrationCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(IL2Bridgehub.allowInteropPeer, (PEER_CHAIN_ID, PEER_BASE_TOKEN_ASSET_ID));
    }

    function _deregistrationCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(IL2Bridgehub.deregisterChainForInterop, (PEER_CHAIN_ID));
    }

    function _resubmissionData(uint256 _peerChainId) internal pure returns (bytes memory) {
        return bytes.concat(CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION, abi.encode(_peerChainId));
    }

    function _peers(uint256 _peerChainId) internal pure returns (uint256[] memory peers) {
        peers = new uint256[](1);
        peers[0] = _peerChainId;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}

    /*//////////////////////////////////////////////////////////////
                            Chain features
    //////////////////////////////////////////////////////////////*/

    /// @dev The chain-feature push to `CHAIN_ID`'s L2 Bridgehub.
    function _expectFeaturePush(bool _enabled) internal {
        vm.expectCall(
            chain,
            abi.encodeCall(
                IMailbox.requestL2ServiceTransaction,
                (L2_BRIDGEHUB_ADDR, abi.encodeCall(IL2Bridgehub.setChainFeatureEnabled, (TEST_FEATURE, _enabled)))
            )
        );
    }

    function _mockBridgehubAdmin(address _admin) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.admin, ()), abi.encode(_admin));
    }

    function _mockProtocolVersion(uint256 _protocolVersion) internal {
        vm.mockCall(chain, abi.encodeCall(IGetters.getProtocolVersion, ()), abi.encode(_protocolVersion));
    }

    function test_setChainFeatureEnabled_byOwnerOrBridgehubAdmin() public {
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        _mockProtocolVersion(CHAIN_FEATURES_MIN_PROTOCOL_VERSION);

        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.ChainFeatureSet(CHAIN_ID, TEST_FEATURE, true);
        _expectFeaturePush(true);
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, TEST_FEATURE, true);
        assertTrue(sender.isChainFeatureEnabled(CHAIN_ID, TEST_FEATURE));
        assertFalse(sender.isChainFeatureEnabled(PEER_CHAIN_ID, TEST_FEATURE));

        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.ChainFeatureSet(CHAIN_ID, TEST_FEATURE, false);
        _expectFeaturePush(false);
        vm.prank(ecosystemAdmin);
        sender.setChainFeatureEnabled(CHAIN_ID, TEST_FEATURE, false);
        assertFalse(sender.isChainFeatureEnabled(CHAIN_ID, TEST_FEATURE));
    }

    /// @notice A chain's admin can't enable a feature for its chain: the ecosystem decides which chains use it.
    function test_setChainFeatureEnabled_revertWhen_chainAdmin() public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainAdmin));
        vm.prank(chainAdmin);
        sender.setChainFeatureEnabled(CHAIN_ID, TEST_FEATURE, true);
    }

    /// @notice A chain whose L2 Bridgehub doesn't have the setter yet can't get a feature: the service transaction
    /// would fail on L2 while L1 shows the feature enabled.
    function test_setChainFeatureEnabled_revertWhen_protocolVersionTooOld() public {
        uint256 oldVersion = CHAIN_FEATURES_MIN_PROTOCOL_VERSION - 1;
        _mockProtocolVersion(oldVersion);
        vm.expectRevert(abi.encodeWithSelector(ChainFeaturesNotSupported.selector, CHAIN_ID, oldVersion));
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, TEST_FEATURE, true);
        assertFalse(sender.isChainFeatureEnabled(CHAIN_ID, TEST_FEATURE));
    }

    function test_setChainFeatureEnabled_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        vm.prank(owner);
        sender.setChainFeatureEnabled(UNREGISTERED_CHAIN_ID, TEST_FEATURE, true);
    }

    /*//////////////////////////////////////////////////////////////
                            Interop root writers
    //////////////////////////////////////////////////////////////*/

    /// @dev The chain id of a source chain outside the ecosystem: not registered in the Bridgehub.
    uint256 internal constant SOURCE_CHAIN_ID = UNREGISTERED_CHAIN_ID;

    /// @dev What the ecosystem does before a chain's admin can name a writer: the feature and the source.
    function _enableInteropRootWriters() internal {
        _mockProtocolVersion(INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION);
        vm.startPrank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, true);
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);
        vm.stopPrank();
    }

    function _expectWriterPush(address _writer) internal {
        vm.expectCall(
            chain,
            abi.encodeCall(
                IMailbox.requestL2ServiceTransaction,
                (
                    L2_INTEROP_ROOT_STORAGE_ADDR,
                    abi.encodeCall(IL2InteropRootStorage.setInteropRootWriter, (SOURCE_CHAIN_ID, _writer))
                )
            )
        );
    }

    function test_setInteropRootWriter_byChainAdmin() public {
        _enableInteropRootWriters();
        address writer = makeAddr("writer");

        vm.expectEmit(true, true, true, true, address(sender));
        emit IChainRegistrationSender.InteropRootWriterSet(CHAIN_ID, SOURCE_CHAIN_ID, writer);
        _expectWriterPush(writer);
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, writer);

        assertEq(sender.interopRootWriter(CHAIN_ID, SOURCE_CHAIN_ID), writer);
        assertEq(sender.interopRootWriter(PEER_CHAIN_ID, SOURCE_CHAIN_ID), address(0), "only the chain's own side");
    }

    /// @notice The ecosystem decides which chains may trust a writer: without the chain feature, the admin can't.
    function test_setInteropRootWriter_revertWhen_featureNotEnabled() public {
        vm.prank(chainAdmin);
        vm.expectRevert(InteropRootWritersNotEnabled.selector);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));
    }

    /// @notice The writers ship in v0.36.0: on an older chain neither setting nor removing one reaches the L2, even
    /// if the feature was recorded as enabled.
    function test_setInteropRootWriter_revertWhen_protocolVersionBelowV36() public {
        assertEq(INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION, 0x2400000000, "v0.36.0");
        uint256 oldVersion = INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION - 1;
        _mockProtocolVersion(CHAIN_FEATURES_MIN_PROTOCOL_VERSION);
        vm.startPrank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, true);
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);
        vm.stopPrank();
        _mockProtocolVersion(oldVersion);

        address[2] memory writers = [makeAddr("writer"), address(0)];
        for (uint256 i = 0; i < writers.length; ++i) {
            vm.prank(chainAdmin);
            vm.expectRevert(abi.encodeWithSelector(InteropRootWritersNotSupported.selector, CHAIN_ID, oldVersion));
            sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, writers[i]);
        }
        assertEq(sender.interopRootWriter(CHAIN_ID, SOURCE_CHAIN_ID), address(0));
    }

    /// @notice Only the chain's admin chooses whom its chain trusts; the ecosystem can only remove a writer.
    function test_setInteropRootWriter_revertWhen_ownerSetsWriter() public {
        _enableInteropRootWriters();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));
    }

    function test_setInteropRootWriter_removalByOwnerBridgehubAdminOrChainAdmin() public {
        _enableInteropRootWriters();
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        address[3] memory removers = [owner, ecosystemAdmin, chainAdmin];
        for (uint256 i = 0; i < removers.length; ++i) {
            vm.prank(chainAdmin);
            sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));

            vm.expectEmit(true, true, true, true, address(sender));
            emit IChainRegistrationSender.InteropRootWriterSet(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
            _expectWriterPush(address(0));
            vm.prank(removers[i]);
            sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
            assertEq(sender.interopRootWriter(CHAIN_ID, SOURCE_CHAIN_ID), address(0));
        }
    }

    function testFuzz_setInteropRootWriter_revertWhen_strangerRemoves(address _caller) public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.assume(_caller != owner && _caller != chainAdmin && _caller != makeAddr("ecosystemAdmin"));
        // The proxy admin can't reach the implementation at all.
        vm.assume(_caller != makeAddr("proxyAdmin"));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
    }

    /// @notice A writer stays removable, by the same three, after the ecosystem disabled the feature: a removal
    /// only takes trust away.
    function test_setInteropRootWriter_removalAfterFeatureDisabled() public {
        _enableInteropRootWriters();
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, false);

        vm.prank(chainAdmin);
        vm.expectRevert(InteropRootWritersNotEnabled.selector);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("newWriter"));

        _expectWriterPush(address(0));
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
        assertEq(sender.interopRootWriter(CHAIN_ID, SOURCE_CHAIN_ID), address(0));
    }

    function test_setInteropRootWriter_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.setInteropRootWriter(UNREGISTERED_CHAIN_ID, SOURCE_CHAIN_ID, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    Exclusive interop root sources
    //////////////////////////////////////////////////////////////*/

    /// @dev Gives the peer chain the writers feature too, so only the assignment separates it from the source.
    function _enableInteropRootWritersForPeer() internal {
        vm.mockCall(
            peer,
            abi.encodeCall(IGetters.getProtocolVersion, ()),
            abi.encode(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION)
        );
        vm.prank(owner);
        sender.setChainFeatureEnabled(PEER_CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, true);
    }

    /// @notice The ecosystem assigns a source chain to one chain: asset ids are derived from the source's chain id,
    /// so a second chain with its own writer for the same id could mint the first chain's assets.
    function test_assignInteropRootSource_byOwnerOrBridgehubAdmin() public {
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        uint256 otherSourceChainId = SOURCE_CHAIN_ID + 1;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (otherSourceChainId)), abi.encode(address(0)));
        assertEq(sender.interopRootSourceChain(SOURCE_CHAIN_ID), 0);

        vm.expectEmit(true, true, false, false, address(sender));
        emit IChainRegistrationSender.InteropRootSourceAssigned(SOURCE_CHAIN_ID, CHAIN_ID);
        vm.prank(owner);
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);
        assertEq(sender.interopRootSourceChain(SOURCE_CHAIN_ID), CHAIN_ID);
        assertFalse(sender.isInteropRootSourceUsed(SOURCE_CHAIN_ID));

        // A chain can have several sources; a source has one chain.
        vm.prank(ecosystemAdmin);
        sender.assignInteropRootSource(otherSourceChainId, CHAIN_ID);
        assertEq(sender.interopRootSourceChain(otherSourceChainId), CHAIN_ID);

        address[2] memory assigners = [owner, ecosystemAdmin];
        uint256[2] memory chains = [PEER_CHAIN_ID, CHAIN_ID];
        for (uint256 i = 0; i < assigners.length; ++i) {
            vm.prank(assigners[i]);
            vm.expectRevert(
                abi.encodeWithSelector(InteropRootSourceAlreadyAssigned.selector, SOURCE_CHAIN_ID, CHAIN_ID)
            );
            sender.assignInteropRootSource(SOURCE_CHAIN_ID, chains[i]);
        }
    }

    /// @notice A chain's admin does not pick its own sources: with first-come claims a chain could take the id of
    /// another chain's source, or of a chain about to be registered.
    function testFuzz_assignInteropRootSource_revertWhen_notOwnerNorBridgehubAdmin(address _caller) public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.assume(_caller != owner && _caller != makeAddr("ecosystemAdmin"));
        vm.assume(_caller != makeAddr("proxyAdmin"));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);
    }

    function test_assignInteropRootSource_revertWhen_chainAdmin() public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainAdmin));
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);
    }

    /// @notice The roots of L1 and of every ZK chain, the chain itself included, reach a chain through its
    /// settlement layer; none of them is a source of written roots.
    function test_assignInteropRootSource_revertWhen_sourceIsL1OrZKChain() public {
        uint256[3] memory sources = [block.chainid, CHAIN_ID, PEER_CHAIN_ID];
        for (uint256 i = 0; i < sources.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootSource.selector, sources[i]));
            sender.assignInteropRootSource(sources[i], CHAIN_ID);
        }
    }

    function test_assignInteropRootSource_revertWhen_chainNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, UNREGISTERED_CHAIN_ID);
    }

    /// @notice Only the chain a source is assigned to names a writer for it, and the first writer makes the
    /// assignment permanent: what the chain minted from the source's roots stays on it.
    function test_setInteropRootWriter_revertWhen_sourceNotAssignedToTheChain() public {
        _mockProtocolVersion(INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION);
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, true);
        _enableInteropRootWritersForPeer();

        // Not assigned to anyone.
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropRootSourceNotAssigned.selector, CHAIN_ID, SOURCE_CHAIN_ID));
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));

        vm.prank(owner);
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);
        vm.expectEmit(true, true, false, false, address(sender));
        emit IChainRegistrationSender.InteropRootSourceUsed(SOURCE_CHAIN_ID, CHAIN_ID);
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));
        assertTrue(sender.isInteropRootSourceUsed(SOURCE_CHAIN_ID));

        // Assigned to another chain, whatever that chain does with its writer afterwards.
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
        vm.prank(makeAddr("peerAdmin"));
        vm.expectRevert(abi.encodeWithSelector(InteropRootSourceNotAssigned.selector, PEER_CHAIN_ID, SOURCE_CHAIN_ID));
        sender.setInteropRootWriter(PEER_CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("peerWriter"));
        assertEq(sender.interopRootWriter(PEER_CHAIN_ID, SOURCE_CHAIN_ID), address(0));
        assertEq(sender.interopRootSourceChain(SOURCE_CHAIN_ID), CHAIN_ID);
    }

    /// @notice The owner or the Bridgehub admin undoes an assignment the chain never used, and the source can
    /// then go to another chain.
    function test_releaseInteropRootSource_beforeUse() public {
        _enableInteropRootWritersForPeer();
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        address[2] memory releasers = [owner, ecosystemAdmin];
        for (uint256 i = 0; i < releasers.length; ++i) {
            vm.prank(owner);
            sender.assignInteropRootSource(SOURCE_CHAIN_ID, CHAIN_ID);

            vm.expectEmit(true, true, false, false, address(sender));
            emit IChainRegistrationSender.InteropRootSourceReleased(SOURCE_CHAIN_ID, CHAIN_ID);
            vm.prank(releasers[i]);
            sender.releaseInteropRootSource(SOURCE_CHAIN_ID);
            assertEq(sender.interopRootSourceChain(SOURCE_CHAIN_ID), 0);
        }

        vm.prank(owner);
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, PEER_CHAIN_ID);
        vm.prank(makeAddr("peerAdmin"));
        sender.setInteropRootWriter(PEER_CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("peerWriter"));
        assertEq(sender.interopRootWriter(PEER_CHAIN_ID, SOURCE_CHAIN_ID), makeAddr("peerWriter"));
    }

    /// @notice An assignment the chain used is never undone, in whatever order the chain removes its writer and its
    /// counterparts afterwards: the tokens the chain minted from the source's roots outlive both, and a second
    /// chain backing the same asset ids would have to honour them.
    function test_releaseInteropRootSource_revertWhen_used() public {
        _setWriterAndV37();
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);

        // With a writer only.
        _expectReleaseRefused(owner);
        vm.prank(chainAdmin);
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));
        _expectReleaseRefused(owner);
        // With counterparts only.
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
        _expectReleaseRefused(ecosystemAdmin);
        // With neither any more.
        vm.prank(chainAdmin);
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, address(0), address(0));
        _expectReleaseRefused(owner);
        _expectReleaseRefused(ecosystemAdmin);

        assertEq(sender.interopRootSourceChain(SOURCE_CHAIN_ID), CHAIN_ID);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InteropRootSourceAlreadyAssigned.selector, SOURCE_CHAIN_ID, CHAIN_ID));
        sender.assignInteropRootSource(SOURCE_CHAIN_ID, PEER_CHAIN_ID);
    }

    function _expectReleaseRefused(address _releaser) internal {
        vm.prank(_releaser);
        vm.expectRevert(abi.encodeWithSelector(InteropRootSourceInUse.selector, SOURCE_CHAIN_ID, CHAIN_ID));
        sender.releaseInteropRootSource(SOURCE_CHAIN_ID);
    }

    /// @notice A chain's admin can't free its own source: the ecosystem decides when a source changes hands.
    function testFuzz_releaseInteropRootSource_revertWhen_notOwnerNorBridgehubAdmin(address _caller) public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.assume(_caller != owner && _caller != makeAddr("ecosystemAdmin"));
        vm.assume(_caller != makeAddr("proxyAdmin"));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        sender.releaseInteropRootSource(SOURCE_CHAIN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                        Interop counterparts
    //////////////////////////////////////////////////////////////*/

    address internal l1AssetRouter = makeAddr("l1AssetRouter");
    address internal l1InteropCenter = makeAddr("l1InteropCenter");

    function _mockL1InteropCenter(address _l1InteropCenter) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(l1AssetRouter));
        vm.mockCall(l1AssetRouter, abi.encodeCall(IL1AssetRouter.l1InteropCenter, ()), abi.encode(_l1InteropCenter));
    }

    function _enableL1ToL2Interop() internal {
        _mockL1InteropCenter(l1InteropCenter);
        _mockProtocolVersion(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION);
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, L1_TO_L2_INTEROP_FEATURE, true);
    }

    function _expectCounterpartsPush(uint256 _sourceChainId, address _interopCenter, address _assetRouter) internal {
        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropCounterpartsSet(CHAIN_ID, _sourceChainId, _interopCenter, _assetRouter);
        vm.expectCall(
            chain,
            abi.encodeCall(
                IMailbox.requestL2ServiceTransaction,
                (
                    L2_BRIDGEHUB_ADDR,
                    abi.encodeCall(IL2Bridgehub.setInteropCounterparts, (_sourceChainId, _interopCenter, _assetRouter))
                )
            )
        );
    }

    function _assertCounterparts(uint256 _sourceChainId, address _interopCenter, address _assetRouter) internal view {
        InteropCounterparts memory stored = sender.interopCounterparts(CHAIN_ID, _sourceChainId);
        assertEq(stored.interopCenter, _interopCenter);
        assertEq(stored.assetRouter, _assetRouter);
    }

    /// @notice The counterparts of L1 are this L1's own interop center and asset router: the caller supplies no
    /// address.
    function test_setL1InteropCounterparts_byChainAdmin() public {
        _enableL1ToL2Interop();

        _expectCounterpartsPush(block.chainid, l1InteropCenter, l1AssetRouter);
        vm.prank(chainAdmin);
        sender.setL1InteropCounterparts(CHAIN_ID, true);

        _assertCounterparts(block.chainid, l1InteropCenter, l1AssetRouter);
        InteropCounterparts memory peerSide = sender.interopCounterparts(PEER_CHAIN_ID, block.chainid);
        assertEq(peerSide.interopCenter, address(0), "only the chain's own side");
    }

    /// @notice The ecosystem decides which chains execute bundles of L1: without the chain feature, the admin can't.
    function test_setL1InteropCounterparts_revertWhen_featureNotEnabled() public {
        _mockL1InteropCenter(l1InteropCenter);
        _mockProtocolVersion(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainFeatureNotEnabled.selector, L1_TO_L2_INTEROP_FEATURE));
        sender.setL1InteropCounterparts(CHAIN_ID, true);
    }

    /// @notice The chain's admin opts its chain in; the ecosystem can only remove the counterparts.
    function test_setL1InteropCounterparts_revertWhen_ownerSets() public {
        _enableL1ToL2Interop();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        sender.setL1InteropCounterparts(CHAIN_ID, true);
    }

    function test_setL1InteropCounterparts_revertWhen_l1HasNoInteropCenter() public {
        _enableL1ToL2Interop();
        _mockL1InteropCenter(address(0));
        vm.prank(chainAdmin);
        vm.expectRevert(ZeroAddress.selector);
        sender.setL1InteropCounterparts(CHAIN_ID, true);
    }

    /// @notice The counterparts ship in v0.37.0: on an older chain neither setting nor removing them reaches the L2.
    function test_setL1InteropCounterparts_revertWhen_protocolVersionBelowV37() public {
        assertEq(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION, 0x2500000000, "v0.37.0");
        _enableL1ToL2Interop();
        uint256 oldVersion = INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION - 1;
        _mockProtocolVersion(oldVersion);

        bool[2] memory set = [true, false];
        for (uint256 i = 0; i < set.length; ++i) {
            vm.prank(chainAdmin);
            vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsNotSupported.selector, CHAIN_ID, oldVersion));
            sender.setL1InteropCounterparts(CHAIN_ID, set[i]);
        }
        _assertCounterparts(block.chainid, address(0), address(0));
    }

    function test_setL1InteropCounterparts_removalByOwnerBridgehubAdminOrChainAdmin() public {
        _enableL1ToL2Interop();
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        address[3] memory removers = [owner, ecosystemAdmin, chainAdmin];
        for (uint256 i = 0; i < removers.length; ++i) {
            vm.prank(chainAdmin);
            sender.setL1InteropCounterparts(CHAIN_ID, true);

            _expectCounterpartsPush(block.chainid, address(0), address(0));
            vm.prank(removers[i]);
            sender.setL1InteropCounterparts(CHAIN_ID, false);
            _assertCounterparts(block.chainid, address(0), address(0));
        }
    }

    function testFuzz_setL1InteropCounterparts_revertWhen_strangerRemoves(address _caller) public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.assume(_caller != owner && _caller != chainAdmin && _caller != makeAddr("ecosystemAdmin"));
        vm.assume(_caller != makeAddr("proxyAdmin"));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        sender.setL1InteropCounterparts(CHAIN_ID, false);
    }

    function test_setL1InteropCounterparts_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.setL1InteropCounterparts(UNREGISTERED_CHAIN_ID, true);
    }

    function _setWriterAndV37() internal {
        _enableInteropRootWriters();
        _mockProtocolVersion(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION);
        vm.prank(chainAdmin);
        sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));
    }

    /// @notice A chain whose roots come from a writer gets the counterparts its chain admin names.
    function test_setInteropCounterparts_byChainAdmin() public {
        _setWriterAndV37();
        address center = makeAddr("sourceCenter");
        address router = makeAddr("sourceRouter");

        _expectCounterpartsPush(SOURCE_CHAIN_ID, center, router);
        vm.prank(chainAdmin);
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, center, router);
        _assertCounterparts(SOURCE_CHAIN_ID, center, router);

        // The counterparts can be replaced: a new interop center on the source needs it.
        address newCenter = makeAddr("newSourceCenter");
        _expectCounterpartsPush(SOURCE_CHAIN_ID, newCenter, router);
        vm.prank(chainAdmin);
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, newCenter, router);
        _assertCounterparts(SOURCE_CHAIN_ID, newCenter, router);
    }

    /// @notice Without a writer the chain could never execute the source's bundles, and its asset tracker would not
    /// apply the origin rule to the source, so the counterparts come second.
    function test_setInteropCounterparts_revertWhen_noWriter() public {
        _enableInteropRootWriters();
        _mockProtocolVersion(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropRootWriterNotSet.selector, CHAIN_ID, SOURCE_CHAIN_ID));
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));
    }

    function test_setInteropCounterparts_revertWhen_featureDisabled() public {
        _setWriterAndV37();
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, false);

        vm.prank(chainAdmin);
        vm.expectRevert(InteropRootWritersNotEnabled.selector);
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));
    }

    function test_setInteropCounterparts_revertWhen_onlyOneAddress() public {
        _setWriterAndV37();
        address center = makeAddr("center");
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropCounterparts.selector, center, address(0)));
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, center, address(0));
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropCounterparts.selector, address(0), center));
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, address(0), center);
    }

    function test_setInteropCounterparts_revertWhen_ownerSets() public {
        _setWriterAndV37();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));
    }

    /// @notice A source assigned to another chain gets neither a writer nor counterparts on this chain.
    function test_setInteropCounterparts_revertWhen_sourceAssignedToAnotherChain() public {
        _setWriterAndV37();
        _enableInteropRootWritersForPeer();
        vm.prank(makeAddr("peerAdmin"));
        vm.expectRevert(abi.encodeWithSelector(InteropRootSourceNotAssigned.selector, PEER_CHAIN_ID, SOURCE_CHAIN_ID));
        sender.setInteropRootWriter(PEER_CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("peerWriter"));
        vm.prank(makeAddr("peerAdmin"));
        vm.expectRevert(abi.encodeWithSelector(InteropRootWriterNotSet.selector, PEER_CHAIN_ID, SOURCE_CHAIN_ID));
        sender.setInteropCounterparts(PEER_CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));
    }

    function test_setInteropCounterparts_removalByOwnerBridgehubAdminOrChainAdmin() public {
        _setWriterAndV37();
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        address[3] memory removers = [owner, ecosystemAdmin, chainAdmin];
        for (uint256 i = 0; i < removers.length; ++i) {
            vm.prank(chainAdmin);
            sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));

            _expectCounterpartsPush(SOURCE_CHAIN_ID, address(0), address(0));
            vm.prank(removers[i]);
            sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, address(0), address(0));
            _assertCounterparts(SOURCE_CHAIN_ID, address(0), address(0));
        }
    }

    function testFuzz_setInteropCounterparts_revertWhen_strangerRemoves(address _caller) public {
        _mockBridgehubAdmin(makeAddr("ecosystemAdmin"));
        vm.assume(_caller != owner && _caller != chainAdmin && _caller != makeAddr("ecosystemAdmin"));
        vm.assume(_caller != makeAddr("proxyAdmin"));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, address(0), address(0));
    }

    function test_setInteropCounterparts_revertWhen_protocolVersionBelowV37() public {
        _setWriterAndV37();
        uint256 oldVersion = INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION - 1;
        _mockProtocolVersion(oldVersion);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsNotSupported.selector, CHAIN_ID, oldVersion));
        sender.setInteropCounterparts(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("center"), makeAddr("router"));
    }

    function test_setInteropCounterparts_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.setInteropCounterparts(UNREGISTERED_CHAIN_ID, SOURCE_CHAIN_ID, address(0), address(0));
    }
}
