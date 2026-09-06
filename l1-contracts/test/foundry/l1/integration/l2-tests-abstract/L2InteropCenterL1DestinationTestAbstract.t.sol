// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {L2_INTEROP_CENTER_ADDR, L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {AtomicFlowPreimage, ATOMIC_FLOW_PREIMAGE_VERSION} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    AtomicBundleToL1NotSupported,
    CannotInitiateInteropOnL1,
    DirectCallToL1NotSupported,
    InteropCallToL1NotToAssetRouter,
    InteropToSelfNotSupported,
    MultiCallToL1NotSupported,
    NonZeroValueToL1NotSupported
} from "contracts/interop/InteropErrors.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

/// @notice Covers `InteropCenter` send-time destination and recipient restrictions (L1-destined bundles,
/// self-destination, zero addresses). See {protocol-docs/interop.md#restrictions}.
/// @dev Kept in its own abstract (mixed into `L2InteropCenterTestAbstract`) rather than in
/// `L2InteropLibraryBasicTestAbstract`: that abstract is also inherited by the zksync `L2InteropLibraryTest`, and
/// the extra code would push it over EraVM's 65536-instruction bytecode limit. These checks are fully exercised
/// in the L1 (EVM) context, so no zksync coverage is lost.
abstract contract L2InteropCenterL1DestinationTestAbstract is L2InteropTestUtils {
    /// @notice A single-call token withdrawal to L1 sends and emits `InteropBundleSent`; L1 is not a registered
    /// interop chain, so this also exercises the L1 base-token asset-ID branch on the send side.
    function test_sendToken_ToL1_Succeeds() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        bytes32 bundleHash = InteropLibrary.sendToken(
            L1_CHAIN_ID,
            l2TokenAddress,
            100,
            address(this),
            UNBUNDLER_ADDRESS,
            false,
            bytes32(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(bundleHash != bytes32(0), "L1-destined bundle should return a non-zero hash");
        bool foundBundle;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == L2_INTEROP_CENTER_ADDR &&
                logs[i].topics[0] == IInteropCenter.InteropBundleSent.selector
            ) {
                foundBundle = true;
                break;
            }
        }
        assertTrue(foundBundle, "InteropBundleSent should be emitted for the L1-destined bundle");
    }

    /// @notice A bundle to L1 with more than one call is rejected: an L1-destined bundle is a single call.
    function test_sendBundle_RevertWhen_MultiCallToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, true, 0);
        calls[1] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, true, 0);
        vm.expectRevert(abi.encodeWithSelector(MultiCallToL1NotSupported.selector, uint256(2)));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice A direct (non-indirect) call to L1 is rejected.
    function test_sendBundle_RevertWhen_DirectCallToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, false, 0);
        vm.expectRevert(DirectCallToL1NotSupported.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice An indirect L1 call targeting anything other than the L2 AssetRouter is rejected.
    function test_sendBundle_RevertWhen_CallToL1NotAssetRouter() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(interopTargetContract, true, 0);
        vm.expectRevert(abi.encodeWithSelector(InteropCallToL1NotToAssetRouter.selector, interopTargetContract));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice An L1 call carrying non-zero destination-side value is rejected: the amount must ride in the payload.
    function test_sendBundle_RevertWhen_NonZeroValueToL1() public {
        uint256 callValue = 5;
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, true, callValue);
        vm.expectRevert(abi.encodeWithSelector(NonZeroValueToL1NotSupported.selector, callValue));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice A bundle to L1 with zero calls is rejected: an L1-destined bundle must contain exactly one call.
    function test_sendBundle_RevertWhen_ZeroCallsToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](0);
        vm.expectRevert(abi.encodeWithSelector(MultiCallToL1NotSupported.selector, uint256(0)));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice An L1-destined bundle carrying the `atomicBundle` attribute is rejected (see
    /// {protocol-docs/atomicity/security.md#non-guarantees}); the check fires in `_sendBundle` before any burn or state change.
    function test_sendBundle_RevertWhen_AtomicBundleToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, true, 0);
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));
        // Preimage content is irrelevant: the L1-destination check fires before preimage validation.
        bytes32[] memory legBundleHashes = new bytes32[](1);
        legBundleHashes[0] = keccak256("leg bundle hash");
        uint256[] memory legSourceChainIds = new uint256[](1);
        legSourceChainIds[0] = block.chainid;
        attrs[1] = abi.encodeCall(
            IERC7786Attributes.atomicBundle,
            (
                AtomicFlowPreimage({
                    version: ATOMIC_FLOW_PREIMAGE_VERSION,
                    deadline: uint64(block.timestamp + 1 days),
                    settlementLayerChainId: L1_CHAIN_ID,
                    legBundleHashes: legBundleHashes,
                    legSourceChainIds: legSourceChainIds
                }),
                0
            )
        );
        vm.expectRevert(AtomicBundleToL1NotSupported.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, attrs);
    }

    /// @notice `useFixedFee = true` is ignored for L1-destined bundles (they are free): no ZK-fee collection is
    /// even attempted — the sender holds no ZK tokens, so an attempted collection would revert the send.
    function test_sendToken_ToL1_WithFixedFee_SucceedsWithoutZKFee() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);

        bytes32 bundleHash = InteropLibrary.sendToken(
            L1_CHAIN_ID,
            l2TokenAddress,
            100,
            address(this),
            UNBUNDLER_ADDRESS,
            true, // useFixedFee
            bytes32(uint256(1)) // distinct salt from the non-fixed-fee happy path
        );

        assertTrue(bundleHash != bytes32(0), "fixed-fee L1 bundle should send successfully");
        assertEq(
            l2InteropCenter.accumulatedZKFees(block.coinbase),
            0,
            "no fixed ZK fee may be accumulated for an L1-destined bundle"
        );
    }

    /// @notice A `sendMessage` recipient must carry a concrete address: a chain-only ERC-7930 encoding parses
    /// to address(0) and would lock value in a message that can never execute.
    function test_sendMessage_RevertWhen_RecipientAddressEmpty() public {
        vm.expectRevert(ZeroAddress.selector);
        l2InteropCenter.sendMessage(InteroperableAddress.formatEvmV1(destinationChainId), hex"", new bytes[](0));
    }

    /// @notice A call starter with empty chain-reference AND address fields passes `_ensureEmptyChainReference`
    /// yet parses to address(0) — rejected by the same guard as the `sendMessage` case.
    function test_sendBundle_RevertWhen_CallStarterAddressEmpty() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        // Minimal ERC-7930 v1: version + chainType (0x00010000), chainReferenceLength = 0, addressLength = 0.
        calls[0] = InteropCallStarter({
            to: abi.encodePacked(bytes4(0x00010000), uint8(0), uint8(0)),
            data: hex"",
            callAttributes: new bytes[](0)
        });
        vm.expectRevert(ZeroAddress.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(destinationChainId), calls, _l1BundleAttributes());
    }

    /// @notice A bundle can never target the sending chain itself.
    function test_sendBundle_RevertWhen_DestinationIsSelf() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, true, 0);
        vm.expectRevert(InteropToSelfNotSupported.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(block.chainid), calls, _l1BundleAttributes());
    }

    /// @notice The single-message `sendMessage` path also rejects a self-chain destination (via its own
    /// `_ensureL2ToL2` check, separate from `sendBundle`'s `_ensureValidDestination`).
    function test_sendMessage_RevertWhen_DestinationIsSelf() public {
        vm.expectRevert(InteropToSelfNotSupported.selector);
        l2InteropCenter.sendMessage(
            InteroperableAddress.formatEvmV1(block.chainid, interopTargetContract),
            hex"",
            new bytes[](0)
        );
    }

    /// @notice Interop can never be initiated from L1 itself, regardless of destination.
    function test_l2BuiltIn_rejectsL1Initiation_useL1InteropCenter() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(L2_ASSET_ROUTER_ADDR, true, 0);
        // Pretend the InteropCenter is running on L1.
        vm.chainId(L1_CHAIN_ID);
        vm.expectRevert(CannotInitiateInteropOnL1.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @dev Call starter for the send-time rejection tests: crafted so the specific L1 guard under test is the
    /// first to fire (the L1-branch requires run before `_processCallStarter`).
    function _l1CallStarter(
        address _to,
        bool _indirect,
        uint256 _callValue
    ) internal pure returns (InteropCallStarter memory) {
        uint256 n;
        if (_indirect) ++n;
        if (_callValue != 0) ++n;
        bytes[] memory attrs = new bytes[](n);
        uint256 j;
        if (_indirect) attrs[j++] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        if (_callValue != 0) attrs[j++] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_callValue));
        return InteropCallStarter({to: InteroperableAddress.formatEvmV1(_to), data: hex"", callAttributes: attrs});
    }

    /// @dev Minimal bundle attributes accepted by `sendBundle` (fee is waived for L1 destinations anyway).
    function _l1BundleAttributes() internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));
    }
}
