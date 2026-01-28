// SPDX-License-Identifier: MIT
// ZKSync-compatible version - does not inherit from L1 abstract tests

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {SystemContractsArgs} from "./L2Utils.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";

import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {InteropBundle, MessageInclusionProof, BundleStatus, CallStatus} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";

/// @notice Struct to hold bundle execution result for assertions
struct BundleExecutionResult {
    bytes32 bundleHash;
    uint256 callCount;
    uint256 destinationChainId;
}

contract L2InteropNativeTokenSimpleTest is Test, SharedL2ContractL2Deployer {
    uint256 destinationChainId = 271;

    function test_requestNativeTokenTransferViaLibrary_SameBaseToken() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify bundle was emitted
        assertTrue(logs.length > 0, "Expected logs to be emitted for native token transfer");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Bundle hash should be non-zero");
        assertTrue(result.callCount > 0, "Bundle should contain at least one call for native token transfer");
    }

    function test_supportsAttributes() public view {
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(IERC7786Attributes.indirectCall.selector),
            true,
            "InteropCenter should support indirectCall attribute"
        );
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(
                IERC7786GatewaySource.supportsAttribute.selector
            ),
            false,
            "InteropCenter should not support supportsAttribute as an attribute"
        );
    }

    // Helper functions from L2InteropTestUtils
    function extractAndExecuteSingleBundle(
        Vm.Log[] memory logs,
        uint256 _destinationChainId,
        address executionAddress
    ) internal returns (BundleExecutionResult memory result) {
        bytes memory data = extractFirstBundleFromLogs(logs);
        result = executeBundle(data, executionAddress, _destinationChainId);
    }

    function extractFirstBundleFromLogs(Vm.Log[] memory logs) internal view returns (bytes memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(l2InteropCenter) &&
                logs[i].topics[0] ==
                keccak256(
                    "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes)))"
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
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);

        // Calculate bundle hash for assertions
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);

        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.chainId(_destinationChainId);
        vm.prank(executionAddress);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);

        result = BundleExecutionResult({
            bundleHash: bundleHash,
            callCount: interopBundle.calls.length,
            destinationChainId: _destinationChainId
        });
    }

    /// @notice Asserts that a bundle was executed successfully
    function assertBundleExecuted(BundleExecutionResult memory result) internal view {
        // Verify bundle status is FullyExecuted (value 2)
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(result.bundleHash)),
            2,
            "Bundle status should be FullyExecuted"
        );

        // Verify all call statuses are Executed (value 1)
        for (uint256 i = 0; i < result.callCount; i++) {
            assertEq(
                uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(result.bundleHash, i)),
                1,
                string(abi.encodePacked("Call ", vm.toString(i), " status should be Executed"))
            );
        }
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
