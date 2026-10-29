// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IChainRegistrationSender} from "contracts/core/chain-registration/IChainRegistrationSender.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    ChainHasNoBatchesInMessageRoot,
    InteropAlreadySuspended,
    InteropNotEnabled,
    InteropNotSuspended,
    InteropPeerAlreadyAllowed,
    InvalidInteropPeer,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @notice `ChainRegistrationSender` alone. The Bridgehub, the message root and the chains are mocked to
/// isolate the sender's checks; the end-to-end flow with real contracts is in the integration test
/// `ChainRegistrationSender.t.sol`, and the L2 reads of this state in `Interop/L1Sload/`.
/// See {protocol-docs/interop-gating.md#interop-peer-whitelist} and {protocol-docs/l1sload.md}.
contract ChainRegistrationSenderUnitTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant PEER_CHAIN_ID = 272;
    uint256 internal constant THIRD_CHAIN_ID = 273;
    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;
    bytes32 internal constant PEER_BASE_TOKEN_ASSET_ID = keccak256("peerBaseToken");
    bytes32 internal constant CHAIN_BASE_TOKEN_ASSET_ID = keccak256("chainBaseToken");

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

    /// @notice Allowing writes the pair and the peer's base token snapshot on L1, and sends nothing to L2.
    function test_allowInteropPeer() public {
        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPeerAllowed(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectCall(chain, abi.encodeWithSelector(IMailbox.requestL2ServiceTransaction.selector), 0);
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertFalse(sender.interopPeerAllowed(PEER_CHAIN_ID, CHAIN_ID), "the peer's side needs its own admin");
        assertEq(sender.interopBaseTokenAssetId(PEER_CHAIN_ID), PEER_BASE_TOKEN_ASSET_ID, "the peer's snapshot");
        assertEq(sender.interopBaseTokenAssetId(CHAIN_ID), bytes32(0), "the allowing chain gets none");
    }

    /// @notice The snapshot is the peer's, whichever chain allows it, and stays when the pair is deregistered.
    function test_allowInteropPeer_snapshotIsPerPeer() public {
        _mockChain(THIRD_CHAIN_ID, makeAddr("third"), keccak256("thirdBaseToken"));
        address thirdAdmin = makeAddr("thirdAdmin");
        vm.mockCall(makeAddr("third"), abi.encodeCall(IGetters.getAdmin, ()), abi.encode(thirdAdmin));

        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        vm.prank(thirdAdmin);
        sender.allowInteropPeer(THIRD_CHAIN_ID, PEER_CHAIN_ID);
        assertEq(sender.interopBaseTokenAssetId(PEER_CHAIN_ID), PEER_BASE_TOKEN_ASSET_ID);

        vm.prank(owner);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));
        vm.prank(owner);
        sender.deregisterInteropPairs(THIRD_CHAIN_ID, _peers(PEER_CHAIN_ID));
        assertEq(sender.interopBaseTokenAssetId(PEER_CHAIN_ID), PEER_BASE_TOKEN_ASSET_ID, "kept");
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

    /// @notice A pair L1 never recorded, such as one the retired `registerChain` wrote on L2, deregisters as a no-op.
    function test_deregisterInteropPairs_pairNeverAllowed() public {
        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, PEER_CHAIN_ID);
        vm.prank(owner);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @notice Governance removes a pair on L1 alone, sending nothing to L2; the admin can allow it again.
    function test_deregisterInteropPairs_allowedPair() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.expectEmit(true, true, false, true, address(sender));
        emit IChainRegistrationSender.InteropPairDeregistered(CHAIN_ID, PEER_CHAIN_ID);
        vm.expectCall(chain, abi.encodeWithSelector(IMailbox.requestL2ServiceTransaction.selector), 0);
        vm.prank(owner);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID), "cleared on L1");
        assertEq(sender.interopBaseTokenAssetId(PEER_CHAIN_ID), PEER_BASE_TOKEN_ASSET_ID, "the snapshot stays");

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
        vm.prank(chainAdmin);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @notice Deregistering one side leaves the peer's own side.
    function test_deregisterInteropPairs_keepsThePeersSide() public {
        address peerAdmin = makeAddr("peerAdmin");
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        vm.prank(peerAdmin);
        sender.allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);

        vm.prank(chainAdmin);
        sender.deregisterInteropPairs(CHAIN_ID, _peers(PEER_CHAIN_ID));

        assertFalse(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertTrue(sender.interopPeerAllowed(PEER_CHAIN_ID, CHAIN_ID));
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
                    suspendInterop / resumeInterop
    //////////////////////////////////////////////////////////////*/

    /// @notice Suspension leaves the whitelist and the snapshots alone, so resuming restores the pairs as they were.
    function test_suspendAndResume() public {
        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        vm.expectEmit(true, false, false, true, address(sender));
        emit IChainRegistrationSender.InteropSuspended(CHAIN_ID);
        vm.prank(owner);
        sender.suspendInterop(CHAIN_ID);

        assertTrue(sender.isInteropSuspended(CHAIN_ID));
        assertFalse(sender.isInteropSuspended(PEER_CHAIN_ID), "other chains untouched");
        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID), "the whitelist is untouched");
        assertEq(sender.interopBaseTokenAssetId(PEER_CHAIN_ID), PEER_BASE_TOKEN_ASSET_ID);

        vm.expectEmit(true, false, false, true, address(sender));
        emit IChainRegistrationSender.InteropResumed(CHAIN_ID);
        vm.prank(owner);
        sender.resumeInterop(CHAIN_ID);

        assertFalse(sender.isInteropSuspended(CHAIN_ID));
        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @notice A suspended chain's admin can still edit its whitelist; the suspension gates the L2 reads only.
    function test_suspendedChainCanStillAllowPeers() public {
        vm.prank(owner);
        sender.suspendInterop(CHAIN_ID);

        vm.prank(chainAdmin);
        sender.allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(sender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertTrue(sender.isInteropSuspended(CHAIN_ID));
    }

    function testFuzz_suspendInterop_revertWhen_notOwner(address _caller) public {
        // The proxy admin can only reach the proxy itself.
        vm.assume(_caller != owner && _caller != makeAddr("proxyAdmin"));
        vm.prank(_caller);
        vm.expectRevert("Ownable: caller is not the owner");
        sender.suspendInterop(CHAIN_ID);
        assertFalse(sender.isInteropSuspended(CHAIN_ID));
    }

    function test_suspendInterop_revertWhen_alreadySuspended() public {
        vm.prank(owner);
        sender.suspendInterop(CHAIN_ID);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InteropAlreadySuspended.selector, CHAIN_ID));
        sender.suspendInterop(CHAIN_ID);
    }

    function test_resumeInterop_revertWhen_notSuspended() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InteropNotSuspended.selector, CHAIN_ID));
        sender.resumeInterop(CHAIN_ID);
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

    function _peers(uint256 _peerChainId) internal pure returns (uint256[] memory peers) {
        peers = new uint256[](1);
        peers[0] = _peerChainId;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
