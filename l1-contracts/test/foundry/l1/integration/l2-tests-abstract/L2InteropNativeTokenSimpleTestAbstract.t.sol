// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";

import {L2InteropTestUtils, BundleExecutionResult} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropNativeTokenSimpleTestAbstract is L2InteropTestUtils {
    function test_requestNativeTokenTransferViaLibrary_SameBaseToken() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100, false);
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
}
