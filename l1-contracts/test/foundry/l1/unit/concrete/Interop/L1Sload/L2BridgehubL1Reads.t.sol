// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropAttributeParser} from "contracts/interop/InteropAttributeParser.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {AtomicFlowPreimage, ATOMIC_FLOW_PREIMAGE_VERSION} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {
    DestinationChainNotAllowed,
    DestinationChainNotRegistered,
    InteropPreviewHash
} from "contracts/interop/InteropErrors.sol";
import {L1AnchorStale} from "contracts/common/L1ContractErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    L2_INTEROP_CENTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @dev The L2 Bridgehub entry points that the retired service transactions called.
interface IRetiredL2BridgehubPush {
    function allowInteropPeer(uint256 _chainId, bytes32 _baseTokenAssetId) external;

    function deregisterChainForInterop(uint256 _chainId) external;
}

/// @notice `L2Bridgehub`'s interop gating reads the real L1 `ChainRegistrationSender` through L1SLOAD, and
/// `InteropCenter` sends only where `interopSendTarget` allows. See
/// {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
contract L2BridgehubL1ReadsTest is L1SloadSharedTest {
    uint256 internal constant MAX_NUMBER_OF_ZK_CHAINS = 100;
    uint256 internal constant ANCHOR_BLOCK = 1000;
    uint256 internal constant ANCHOR_TIMESTAMP = 1_700_000_000;

    L2Bridgehub internal l2Bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);
    address internal l2Owner;

    function setUp() public override {
        super.setUp();
        l2Owner = makeAddr("l2Owner");

        vm.etch(L2_BRIDGEHUB_ADDR, address(new L2Bridgehub()).code);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2Bridgehub.initL2(L1_CHAIN_ID, l2Owner, MAX_NUMBER_OF_ZK_CHAINS);
        // As the genesis force deployments do: the L2 Bridgehub stores the aliased L1 `ChainRegistrationSender`.
        vm.prank(l2Owner);
        l2Bridgehub.setAddresses(
            makeAddr("l2AssetRouter"),
            ICTMDeploymentTracker(makeAddr("l1CtmDeployer")),
            IMessageRootBase(makeAddr("l2MessageRoot")),
            makeAddr("l2ChainAssetHandler"),
            AddressAliasHelper.applyL1ToL2Alias(address(chainRegistrationSender))
        );
    }

    /*//////////////////////////////////////////////////////////////
                        The L1 ChainRegistrationSender
    //////////////////////////////////////////////////////////////*/

    function test_l1ChainRegistrationSenderIsTheUnaliasedAddress() public view {
        assertEq(l2Bridgehub.l1ChainRegistrationSender(), address(chainRegistrationSender));
        assertNotEq(l2Bridgehub.chainRegistrationSender(), address(chainRegistrationSender));
    }

    /// @dev Without an anchor every read fails closed before the precompile is called, whatever the clock.
    function testFuzz_revertWhen_noAnchor(uint64 _timestamp) public {
        _onL2();
        vm.warp(_timestamp);
        bytes memory noAnchor = abi.encodeWithSelector(L1AnchorStale.selector, 0, uint256(_timestamp));
        vm.expectRevert(noAnchor);
        l2Bridgehub.isPeerAllowed(PEER_CHAIN_ID);
        vm.expectRevert(noAnchor);
        l2Bridgehub.interopSendTarget(PEER_CHAIN_ID);
        vm.expectRevert(noAnchor);
        l2Bridgehub.interopBaseTokenAssetId(PEER_CHAIN_ID);
    }

    /// @dev The service-transaction entry points are gone: nothing on L2 writes the whitelist.
    function test_servicePushIsGone() public {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert();
        IRetiredL2BridgehubPush(L2_BRIDGEHUB_ADDR).allowInteropPeer(PEER_CHAIN_ID, keccak256("peerBaseToken"));

        vm.prank(l2Bridgehub.chainRegistrationSender());
        vm.expectRevert();
        IRetiredL2BridgehubPush(L2_BRIDGEHUB_ADDR).deregisterChainForInterop(PEER_CHAIN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                        isPeerAllowed (the receive filter)
    //////////////////////////////////////////////////////////////*/

    function test_isPeerAllowed_followsL1State() public {
        _importAnchor();
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID), "this chain's admin has not allowed the peer");

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_isPeerAllowed(THIRD_CHAIN_ID), "other peers unaffected");
        assertFalse(_isPeerAllowed(L1_CHAIN_ID), "L1 is never a peer");
    }

    /// @dev Only this chain's side counts for receiving: the peer's admin choosing this chain is not enough.
    function test_isPeerAllowed_ignoresThePeersSide() public {
        _importAnchor();
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);

        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
    }

    /// @dev Deregistration on L1 refuses the peer on L2 with no service transaction; the peer keeps its own side.
    function test_deregistrationRefusesThePeer() public {
        _importAnchor();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));

        _deregisterInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
        (bool allowed, ) = _interopSendTarget(PEER_CHAIN_ID);
        assertFalse(allowed);

        vm.chainId(PEER_CHAIN_ID);
        assertTrue(l2Bridgehub.isPeerAllowed(CHAIN_ID), "the peer's side is its own admin's");
        (allowed, ) = l2Bridgehub.interopSendTarget(CHAIN_ID);
        assertFalse(allowed, "but it can no longer send to this chain");
    }

    /// @dev One L1 transaction, no service transaction: a suspended peer is refused by every chain at once.
    function test_suspendingThePeerFlipsBothChecks() public {
        _importAnchor();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        (bool allowed, ) = _interopSendTarget(PEER_CHAIN_ID);
        assertTrue(allowed);

        _suspendInterop(PEER_CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
        (allowed, ) = _interopSendTarget(PEER_CHAIN_ID);
        assertFalse(allowed);
        assertTrue(chainRegistrationSender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID), "the whitelist is untouched");

        _resumeInterop(PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        (allowed, ) = _interopSendTarget(PEER_CHAIN_ID);
        assertTrue(allowed);
    }

    /// @dev Reads are pinned to the anchor: an L1 change is invisible until the chain imports an anchor after it.
    /// See {protocol-docs/l1sload.md#freshness}.
    function test_l1ChangeTakesEffectWithTheNextAnchor() public {
        _importAnchor();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);

        vm.prank(governance);
        chainRegistrationSender.suspendInterop(PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID), "the anchor predates the suspension");
        (bool allowed, ) = _interopSendTarget(PEER_CHAIN_ID);
        assertTrue(allowed, "the anchor predates the suspension");

        _importNextL1Anchor();
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
        (allowed, ) = _interopSendTarget(PEER_CHAIN_ID);
        assertFalse(allowed);
    }

    function test_suspendingThisChainRefusesEveryPeer() public {
        _importAnchor();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        _allowBothWays(CHAIN_ID, THIRD_CHAIN_ID);

        _suspendInterop(CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_isPeerAllowed(THIRD_CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                    interopSendTarget / interopBaseTokenAssetId
    //////////////////////////////////////////////////////////////*/

    /// @dev K1: sending needs both admins' consent, receiving only this chain's.
    function test_interopSendTarget_requiresBothSides() public {
        _importAnchor();
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        (bool allowed, bytes32 baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
        assertFalse(allowed, "the peer's admin has not allowed this chain");
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID), "the snapshot is there already");

        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        (allowed, baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
        assertTrue(allowed);
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));
    }

    /// @dev The L2 Bridgehub's own `baseTokenAssetId` registry no longer holds peers.
    function test_interopSendTarget_baseTokenComesFromL1() public {
        _importAnchor();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);

        (, bytes32 baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
        assertEq(baseTokenAssetId, chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID));
        assertEq(l2Bridgehub.baseTokenAssetId(PEER_CHAIN_ID), bytes32(0));
    }

    function test_interopBaseTokenAssetId() public {
        _importAnchor();
        _enableInterop(PEER_CHAIN_ID);
        _enableInterop(THIRD_CHAIN_ID);
        assertEq(_interopBaseTokenAssetId(PEER_CHAIN_ID), bytes32(0));

        // Any chain's admin registers the peer, not only this chain's.
        _allowInteropPeer(THIRD_CHAIN_ID, PEER_CHAIN_ID);
        assertEq(
            _interopBaseTokenAssetId(PEER_CHAIN_ID),
            chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID)
        );
        assertNotEq(_interopBaseTokenAssetId(PEER_CHAIN_ID), bytes32(0));
        assertEq(_interopBaseTokenAssetId(THIRD_CHAIN_ID), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                            InteropCenter
    //////////////////////////////////////////////////////////////*/

    function test_interopCenter_refusesUnregisteredPeer() public {
        _deployInteropCenter();
        _importAnchor();

        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _bundleInputs();
        _onL2();
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, PEER_CHAIN_ID));
        InteropCenter(L2_INTEROP_CENTER_ADDR).sendBundle(
            InteroperableAddress.formatEvmV1(PEER_CHAIN_ID),
            calls,
            bundleAttributes
        );
    }

    function test_interopCenter_refusesOneSidedPeer() public {
        _deployInteropCenter();
        _importAnchor();
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _bundleInputs();
        _onL2();
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotAllowed.selector, PEER_CHAIN_ID));
        InteropCenter(L2_INTEROP_CENTER_ADDR).sendBundle(
            InteroperableAddress.formatEvmV1(PEER_CHAIN_ID),
            calls,
            bundleAttributes
        );
    }

    /// @dev With both sides allowed the bundle passes the destination check; the preview reverts with its hash
    /// right after it.
    function test_interopCenter_acceptsPeerAllowedBothWays() public {
        _deployInteropCenter();
        _importAnchor();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);

        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _bundleInputs();
        _onL2();
        vm.expectPartialRevert(InteropPreviewHash.selector);
        InteropCenter(L2_INTEROP_CENTER_ADDR).previewBundleHash(
            InteroperableAddress.formatEvmV1(PEER_CHAIN_ID),
            calls,
            bundleAttributes
        );

        _onL1();
        _suspendInterop(PEER_CHAIN_ID);
        _onL2();
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotAllowed.selector, PEER_CHAIN_ID));
        InteropCenter(L2_INTEROP_CENTER_ADDR).previewBundleHash(
            InteroperableAddress.formatEvmV1(PEER_CHAIN_ID),
            calls,
            bundleAttributes
        );
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev Imports an anchor so that L1SLOAD works.
    function _importAnchor() internal {
        _importL1Anchor(ANCHOR_BLOCK, keccak256("anchor"), ANCHOR_TIMESTAMP);
    }

    function _isPeerAllowed(uint256 _peerChainId) internal returns (bool allowed) {
        _onL2();
        allowed = l2Bridgehub.isPeerAllowed(_peerChainId);
        _onL1();
    }

    function _interopSendTarget(uint256 _peerChainId) internal returns (bool allowed, bytes32 baseTokenAssetId) {
        _onL2();
        (allowed, baseTokenAssetId) = l2Bridgehub.interopSendTarget(_peerChainId);
        _onL1();
    }

    function _interopBaseTokenAssetId(uint256 _chainId) internal returns (bytes32 assetId) {
        _onL2();
        assetId = l2Bridgehub.interopBaseTokenAssetId(_chainId);
        _onL1();
    }

    function _deployInteropCenter() internal {
        vm.etch(L2_INTEROP_CENTER_ADDR, address(new InteropCenter()).code);
        vm.etch(L2_INTEROP_ATTRIBUTE_PARSER_ADDR, address(new InteropAttributeParser()).code);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        InteropCenter(L2_INTEROP_CENTER_ADDR).initL2(L1_CHAIN_ID, l2Owner, keccak256("zkTokenAssetId"));
    }

    /// @dev A single direct call without value, as an atomic bundle without the fixed fee.
    function _bundleInputs() internal returns (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) {
        calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("target")),
            data: hex"1234",
            callAttributes: new bytes[](0)
        });
        bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));
        bundleAttributes[1] = abi.encodeCall(
            IERC7786Attributes.atomicBundle,
            (
                AtomicFlowPreimage({
                    version: ATOMIC_FLOW_PREIMAGE_VERSION,
                    deadline: type(uint64).max,
                    settlementLayerChainId: 0,
                    legBundleHashes: new bytes32[](0),
                    legSourceChainIds: new uint256[](0)
                }),
                uint256(0)
            )
        );
    }
}
