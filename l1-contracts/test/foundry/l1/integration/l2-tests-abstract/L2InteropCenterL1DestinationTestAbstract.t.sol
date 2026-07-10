// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    CannotInitiateInteropOnL1,
    DirectCallToL1NotSupported,
    MultiCallToL1NotSupported,
    NonZeroValueToL1NotSupported
} from "contracts/interop/InteropErrors.sol";

/// @notice `InteropCenter` send-time constraints for an L2->L1 bundle: it must be exactly one indirect, zero-value
/// call, and interop can never be initiated from L1 itself.
/// @dev Kept in its own abstract (mixed into `L2InteropCenterTestAbstract`, i.e. the L1-context runner) rather than
/// in `L2InteropLibraryBasicTestAbstract`, because that abstract is also inherited by the zksync `L2InteropLibraryTest`
/// and the extra test code would push that contract over EraVM's 65536-instruction bytecode limit. These checks are
/// L2 InteropCenter logic and are fully exercised in the L1 (EVM) context, so no zksync coverage is lost.
abstract contract L2InteropCenterL1DestinationTestAbstract is L2InteropTestUtils {
    /// @notice Happy path: a single-call token withdrawal to L1 sends successfully and emits `InteropBundleSent`.
    /// The L1 destination is not registered as an interop chain, so this also exercises the L1 base-token asset-ID
    /// branch on the send side.
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
        calls[0] = _l1CallStarter(true, 0);
        calls[1] = _l1CallStarter(true, 0);
        vm.expectRevert(abi.encodeWithSelector(MultiCallToL1NotSupported.selector, uint256(2)));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice A direct (non-indirect) call to L1 is rejected: L1 calls must be indirect (asset-router routed).
    function test_sendBundle_RevertWhen_DirectCallToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(false, 0);
        vm.expectRevert(DirectCallToL1NotSupported.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice An L1 call carrying non-zero destination-side value is rejected: the amount must ride in the payload.
    function test_sendBundle_RevertWhen_NonZeroValueToL1() public {
        uint256 callValue = 5;
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(true, callValue);
        vm.expectRevert(abi.encodeWithSelector(NonZeroValueToL1NotSupported.selector, callValue));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice Interop can never be initiated from L1 itself, regardless of destination.
    function test_sendBundle_RevertWhen_InitiatedOnL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(true, 0);
        // Pretend the InteropCenter is running on L1.
        vm.chainId(L1_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(CannotInitiateInteropOnL1.selector, L1_CHAIN_ID));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @dev Builds a single L1-destined call starter. `_indirect` toggles the ERC-7786 indirectCall attribute;
    /// `_callValue` (when non-zero) adds an interopCallValue attribute. The target is a placeholder — these are
    /// only used for send-time rejection tests.
    function _l1CallStarter(bool _indirect, uint256 _callValue) internal view returns (InteropCallStarter memory) {
        uint256 n;
        if (_indirect) ++n;
        if (_callValue != 0) ++n;
        bytes[] memory attrs = new bytes[](n);
        uint256 j;
        if (_indirect) attrs[j++] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        if (_callValue != 0) attrs[j++] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_callValue));
        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(interopTargetContract),
                data: hex"",
                callAttributes: attrs
            });
    }

    /// @dev Minimal bundle attributes accepted by `sendBundle` (fee is waived for L1 destinations anyway).
    function _l1BundleAttributes() internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));
    }
}
