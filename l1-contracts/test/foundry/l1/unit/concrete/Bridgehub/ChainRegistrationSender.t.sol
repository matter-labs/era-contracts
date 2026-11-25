// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {
    CHAIN_FEATURES_MIN_PROTOCOL_VERSION,
    CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION,
    ChainRegistrationSender,
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
import {INTEROP_ROOT_WRITERS_FEATURE, TWO_BRIDGES_MAGIC_VALUE} from "contracts/common/Config.sol";
import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {
    InteropRootWritersNotEnabled,
    InteropRootWritersNotSupported,
    InvalidInteropRootSource
} from "contracts/interop/InteropErrors.sol";
import {Unauthorized, UnsupportedEncodingVersion} from "contracts/common/L1ContractErrors.sol";
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

    function _enableInteropRootWriters() internal {
        _mockProtocolVersion(INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION);
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, true);
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
        vm.prank(owner);
        sender.setChainFeatureEnabled(CHAIN_ID, INTEROP_ROOT_WRITERS_FEATURE, true);
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

    /// @notice The roots of L1, of the chain itself and of every ZK chain reach the chain through its settlement
    /// layer; a writer can't be named for them.
    function test_setInteropRootWriter_revertWhen_sourceIsL1SelfOrZKChain() public {
        _enableInteropRootWriters();
        uint256[3] memory sources = [block.chainid, CHAIN_ID, PEER_CHAIN_ID];
        for (uint256 i = 0; i < sources.length; ++i) {
            vm.prank(chainAdmin);
            vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootSource.selector, sources[i]));
            sender.setInteropRootWriter(CHAIN_ID, sources[i], makeAddr("writer"));
        }
    }

    /// @notice A writer stays removable after its source chain id is registered as a ZK chain, the collision the
    /// source check exists to prevent.
    function test_setInteropRootWriter_removalAfterSourceBecameZKChain() public {
        _enableInteropRootWriters();
        address ecosystemAdmin = makeAddr("ecosystemAdmin");
        _mockBridgehubAdmin(ecosystemAdmin);
        address[3] memory removers = [owner, ecosystemAdmin, chainAdmin];
        for (uint256 i = 0; i < removers.length; ++i) {
            vm.mockCall(
                bridgehub,
                abi.encodeCall(IBridgehubBase.getZKChain, (SOURCE_CHAIN_ID)),
                abi.encode(address(0))
            );
            vm.prank(chainAdmin);
            sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));

            vm.mockCall(
                bridgehub,
                abi.encodeCall(IBridgehubBase.getZKChain, (SOURCE_CHAIN_ID)),
                abi.encode(makeAddr("sourceNowAZKChain"))
            );
            vm.prank(chainAdmin);
            vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootSource.selector, SOURCE_CHAIN_ID));
            sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, makeAddr("writer"));

            _expectWriterPush(address(0));
            vm.prank(removers[i]);
            sender.setInteropRootWriter(CHAIN_ID, SOURCE_CHAIN_ID, address(0));
            assertEq(sender.interopRootWriter(CHAIN_ID, SOURCE_CHAIN_ID), address(0));
        }
    }

    function test_setInteropRootWriter_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        sender.setInteropRootWriter(UNREGISTERED_CHAIN_ID, SOURCE_CHAIN_ID, address(0));
    }
}
