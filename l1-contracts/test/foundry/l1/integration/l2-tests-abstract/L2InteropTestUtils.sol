// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InteropBundle} from "contracts/common/Messaging.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";

/// @notice Struct to hold bundle execution result for assertions
struct BundleExecutionResult {
    bytes32 bundleHash;
    uint256 callCount;
    uint256 destinationChainId;
}

abstract contract L2InteropTestUtils is Test, SharedL2ContractDeployer {
    uint256 destinationChainId = 271;
    bytes32 destinationBaseTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

    /// @dev The AtomicFlowManager `append`/`requireFlowFinalized` gates are mocked to succeed in
    /// {SharedL2ContractDeployer.setUp} (installed unconditionally there, inert for non-interop suites), so
    /// interop concretes need no setUp/MRO boilerplate. The IMT proof machinery itself is exercised
    /// end-to-end in the anvil-interop atomic-swap spec.

    /// @notice Returns a copy of `_attrs` with the mandatory ERC-7786 `atomicBundle` attribute appended.
    /// @dev Every interop send must be atomic (see {InteropCenter}); without this attribute the send
    ///      reverts with `NonAtomicSendUnsupported`. The flow metadata is a placeholder because the
    ///      `AtomicFlowManager.append` gate is mocked in setUp. Use this to wrap inline attribute arrays;
    ///      arrays produced by {InteropLibrary.buildBundleAttributes} already include the attribute.
    function _withAtomicBundle(bytes[] memory _attrs) internal pure returns (bytes[] memory out) {
        out = new bytes[](_attrs.length + 1);
        for (uint256 i = 0; i < _attrs.length; ++i) {
            out[i] = _attrs[i];
        }
        out[_attrs.length] = abi.encodeCall(
            IERC7786Attributes.atomicBundle,
            (bytes32(uint256(1)), type(uint64).max, uint256(0))
        );
    }

    function extractAndExecuteSingleBundle(
        Vm.Log[] memory logs,
        uint256 _destinationChainId,
        address executionAddress
    ) internal returns (BundleExecutionResult memory result) {
        bytes memory data = extractFirstBundleFromLogs(logs);
        result = executeBundle(data, executionAddress, _destinationChainId);
    }

    function extractFirstBundleFromLogs(Vm.Log[] memory logs) internal returns (bytes memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(l2InteropCenter) &&
                logs[i].topics[0] ==
                    keccak256(
                        "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes,bool,bytes32)))"
                    )
            ) {
                data = logs[i].data;
                break;
            }
        }
    }

    function executeBundle(
        bytes memory logsData,
        address executionAddress,
        uint256 _destinationChainId
    ) internal returns (BundleExecutionResult memory result) {
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);

        // Interop is atomic: the cross-chain binding is the bundle's own sourceChainId, and finality is
        // proven via the AtomicFlowManager's IMT gate. We mock that gate to succeed here (the IMT-proof
        // machinery is exercised end-to-end in the anvil-interop atomic-swap spec, not in these unit-level
        // Foundry tests). A default AtomicFinalityProof suffices since the gate is mocked.
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(interopBundle.sourceChainId, bundle);
        AtomicFinalityProof memory finality;

        vm.mockCall(
            L2_ATOMIC_FLOW_MANAGER_ADDR,
            abi.encodeWithSelector(IAtomicFlowManager.requireFlowFinalized.selector),
            ""
        );
        vm.chainId(_destinationChainId);
        vm.prank(executionAddress);
        L2_INTEROP_HANDLER.executeAtomicBundle(bundle, finality);

        result = BundleExecutionResult({
            bundleHash: bundleHash,
            callCount: interopBundle.calls.length,
            destinationChainId: _destinationChainId
        });
    }

    /// @notice Asserts that a bundle was executed successfully
    /// @param result The bundle execution result to verify
    function assertBundleExecuted(BundleExecutionResult memory result) internal view {
        // Verify bundle status is FullyExecuted (value 2)
        assertEq(
            uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(result.bundleHash)),
            2,
            "Bundle status should be FullyExecuted"
        );

        // Verify all call statuses are Executed (value 1)
        for (uint256 i = 0; i < result.callCount; i++) {
            assertEq(
                uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(result.bundleHash, i)),
                1,
                string(abi.encodePacked("Call ", vm.toString(i), " status should be Executed"))
            );
        }
    }
}
