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
import {
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    L2_INTEROP_CENTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice `L2Bridgehub` gating reads the real L1 `ChainRegistrationSender` through the mock precompile, and
/// `InteropCenter` sends only where `interopSendTarget` allows. See
/// {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
contract L2BridgehubL1ReadsTest is L1SloadSharedTest {
    L2Bridgehub internal l2Bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);
    address internal l2Owner;

    function setUp() public override {
        super.setUp();
        l2Owner = makeAddr("l2Owner");

        vm.etch(L2_BRIDGEHUB_ADDR, address(new L2Bridgehub()).code);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2Bridgehub.initL2(L1_CHAIN_ID, l2Owner, 100);
        // As the genesis force deployments do: the L2 Bridgehub stores the aliased L1 `ChainRegistrationSender`.
        vm.prank(l2Owner);
        l2Bridgehub.setAddresses(
            makeAddr("l2AssetRouter"),
            ICTMDeploymentTracker(makeAddr("l1CtmDeployer")),
            IMessageRootBase(makeAddr("l2MessageRoot")),
            makeAddr("l2ChainAssetHandler"),
            AddressAliasHelper.applyL1ToL2Alias(address(chainRegistrationSender))
        );
        _importL1Anchor(1000, keccak256("anchor"), block.timestamp);
    }

    function test_l1ChainRegistrationSenderIsTheUnaliasedAddress() public view {
        assertEq(l2Bridgehub.l1ChainRegistrationSender(), address(chainRegistrationSender));
    }

    /// @dev Receiving needs only this chain's allowance.
    function test_isPeerAllowed() public {
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID), "the peer's side does not count");

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_isPeerAllowed(THIRD_CHAIN_ID));

        _deregisterInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
    }

    /// @dev Sending needs both allowances; the peer's base token comes from the L1 snapshot.
    function test_interopSendTarget() public {
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        (bool allowed, bytes32 baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
        assertFalse(allowed);
        assertEq(baseTokenAssetId, bytes32(0), "no chain allowed the peer yet");

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        (allowed, baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
        assertFalse(allowed, "the peer's admin has not allowed this chain");
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(_interopBaseTokenAssetId(PEER_CHAIN_ID), baseTokenAssetId);

        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        (allowed, baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
        assertTrue(allowed);
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(l2Bridgehub.baseTokenAssetId(PEER_CHAIN_ID), bytes32(0), "the local registry holds no peers");
    }

    /// @dev A suspension of either chain refuses the pair in both directions, and resuming restores it.
    function test_suspension() public {
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);

        uint256[2] memory suspended = [CHAIN_ID, PEER_CHAIN_ID];
        for (uint256 i = 0; i < suspended.length; ++i) {
            _suspendInterop(suspended[i]);
            assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
            (bool allowed, bytes32 baseTokenAssetId) = _interopSendTarget(PEER_CHAIN_ID);
            assertFalse(allowed);
            assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID), "a suspension keeps the snapshot");

            _resumeInterop(suspended[i]);
            assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        }
    }

    /// @dev Reads are pinned to the anchor: an L1 change is invisible until the next import.
    function test_l1ChangeTakesEffectWithTheNextAnchor() public {
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);

        vm.prank(governance);
        chainRegistrationSender.suspendInterop(PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));

        _importNextL1Anchor();
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
    }

    function test_interopCenter_refusesUnregisteredPeer() public {
        _deployInteropCenter();
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

    /// @dev Past the destination check the preview reverts with the bundle hash.
    function test_interopCenter_acceptsPeerAllowedBothWays() public {
        _deployInteropCenter();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _bundleInputs();

        _onL2();
        vm.expectPartialRevert(InteropPreviewHash.selector);
        InteropCenter(L2_INTEROP_CENTER_ADDR).previewBundleHash(
            InteroperableAddress.formatEvmV1(PEER_CHAIN_ID),
            calls,
            bundleAttributes
        );
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
