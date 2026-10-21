// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropAttributeParser} from "contracts/interop/InteropAttributeParser.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {AtomicFlowPreimage, ATOMIC_FLOW_PREIMAGE_VERSION} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {DestinationChainNotAllowed, InteropPreviewHash} from "contracts/interop/InteropErrors.sol";
import {L1SloadFailed} from "contracts/common/L1ContractErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    L2_INTEROP_CENTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice `L2Bridgehub.isPeerAllowed` / `canSendTo` read from the real L1 gating contracts through L1SLOAD, and
/// `InteropCenter` sends only where `canSendTo` holds. See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
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

        // The service transactions of `allowInteropPeer` (CHAIN -> PEER and CHAIN -> THIRD) already arrived, so
        // the mirror holds this chain's side and the peers' base tokens are known.
        vm.startPrank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.allowInteropPeer(PEER_CHAIN_ID, keccak256("peerBaseToken"));
        l2Bridgehub.allowInteropPeer(THIRD_CHAIN_ID, keccak256("thirdBaseToken"));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    Without L1 read addresses: the mirror
    //////////////////////////////////////////////////////////////*/

    function test_withoutL1ReadAddresses_readsTheMirror() public {
        _onL2();
        assertTrue(l2Bridgehub.isPeerAllowed(PEER_CHAIN_ID));
        assertTrue(l2Bridgehub.canSendTo(PEER_CHAIN_ID), "only this chain's side is known");
        assertFalse(l2Bridgehub.isPeerAllowed(L1_CHAIN_ID));

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2Bridgehub.deregisterChainForInterop(PEER_CHAIN_ID);
        assertFalse(l2Bridgehub.isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(l2Bridgehub.canSendTo(PEER_CHAIN_ID));
    }

    function test_setL1ReadAddresses() public {
        vm.expectEmit(address(l2Bridgehub));
        emit IL2Bridgehub.L1ReadAddressesSet(address(l1MessageRoot), address(chainRegistrationSender));
        vm.prank(l2Owner);
        l2Bridgehub.setL1ReadAddresses(address(l1MessageRoot), address(chainRegistrationSender));

        assertEq(l2Bridgehub.l1MessageRoot(), address(l1MessageRoot));
        assertEq(l2Bridgehub.l1ChainRegistrationSender(), address(chainRegistrationSender));
    }

    function test_setL1ReadAddresses_revertWhen_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        l2Bridgehub.setL1ReadAddresses(address(l1MessageRoot), address(chainRegistrationSender));
    }

    /// @dev Zero addresses switch back to the mirror.
    function test_clearingL1ReadAddressesRestoresTheMirror() public {
        _readFromL1();
        _onL2();
        assertFalse(l2Bridgehub.isPeerAllowed(PEER_CHAIN_ID), "nothing is enabled on L1");

        vm.prank(l2Owner);
        l2Bridgehub.setL1ReadAddresses(address(0), address(0));
        assertTrue(l2Bridgehub.isPeerAllowed(PEER_CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                    With L1 read addresses: the L1 state
    //////////////////////////////////////////////////////////////*/

    /// @dev Without an anchor the precompile reverts, and the read fails closed.
    function test_revertWhen_noAnchor() public {
        vm.prank(l2Owner);
        l2Bridgehub.setL1ReadAddresses(address(l1MessageRoot), address(chainRegistrationSender));

        _onL2();
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, address(l1MessageRoot)));
        l2Bridgehub.isPeerAllowed(PEER_CHAIN_ID);
    }

    /// @dev The mirror says "allowed" all along; the L1 state decides once the reads are on.
    function test_isPeerAllowed_followsL1State() public {
        _readFromL1();
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID), "neither chain enabled");

        _enableInterop(CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID), "peer not enabled");

        _enableInterop(PEER_CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID), "this chain's admin has not allowed the peer");

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_isPeerAllowed(THIRD_CHAIN_ID), "other peers unaffected");
    }

    /// @dev Only this chain's side counts for receiving: the peer's admin choosing this chain is not enough.
    function test_isPeerAllowed_ignoresThePeersSide() public {
        _readFromL1();
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);

        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
    }

    /// @dev One L1 transaction, no service transaction: a suspended peer is refused by every chain at once.
    function test_suspendingThePeerFlipsBothChecks() public {
        _readFromL1();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        assertTrue(_canSendTo(PEER_CHAIN_ID));

        _suspendInterop(PEER_CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_canSendTo(PEER_CHAIN_ID));
        assertTrue(l1MessageRoot.isInteropEnabled(PEER_CHAIN_ID), "enabling is untouched");

        _resumeInterop(PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        assertTrue(_canSendTo(PEER_CHAIN_ID));
    }

    function test_suspendingThisChainRefusesEveryPeer() public {
        _readFromL1();
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        _allowBothWays(CHAIN_ID, THIRD_CHAIN_ID);

        _suspendInterop(CHAIN_ID);
        assertFalse(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_isPeerAllowed(THIRD_CHAIN_ID));
    }

    /// @dev K1: `canSendTo` needs both admins' consent, `isPeerAllowed` only this chain's.
    function test_canSendTo_requiresBothSides() public {
        _readFromL1();
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(_isPeerAllowed(PEER_CHAIN_ID));
        assertFalse(_canSendTo(PEER_CHAIN_ID), "the peer's admin has not allowed this chain");

        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        assertTrue(_canSendTo(PEER_CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                            InteropCenter
    //////////////////////////////////////////////////////////////*/

    function test_interopCenter_refusesOneSidedPeer() public {
        _deployInteropCenter();
        _readFromL1();
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
        _readFromL1();
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

    /// @dev Points the L2 Bridgehub at the L1 contracts and imports an anchor so that L1SLOAD works.
    function _readFromL1() internal {
        vm.prank(l2Owner);
        l2Bridgehub.setL1ReadAddresses(address(l1MessageRoot), address(chainRegistrationSender));
        _importL1Anchor(ANCHOR_BLOCK, keccak256("anchor"), ANCHOR_TIMESTAMP);
    }

    function _allowBothWays(uint256 _chainId, uint256 _peerChainId) internal {
        if (!l1MessageRoot.isInteropEnabled(_chainId)) {
            _enableInterop(_chainId);
        }
        if (!l1MessageRoot.isInteropEnabled(_peerChainId)) {
            _enableInterop(_peerChainId);
        }
        _allowInteropPeer(_chainId, _peerChainId);
        _allowInteropPeer(_peerChainId, _chainId);
    }

    function _isPeerAllowed(uint256 _peerChainId) internal returns (bool allowed) {
        _onL2();
        allowed = l2Bridgehub.isPeerAllowed(_peerChainId);
        _onL1();
    }

    function _canSendTo(uint256 _peerChainId) internal returns (bool allowed) {
        _onL2();
        allowed = l2Bridgehub.canSendTo(_peerChainId);
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
