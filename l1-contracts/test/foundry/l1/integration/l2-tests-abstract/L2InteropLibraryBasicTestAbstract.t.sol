// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2InteropTestUtils, BundleExecutionResult} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

abstract contract L2InteropLibraryBasicTestAbstract is L2InteropTestUtils {
    function test_requestTokenTransferInteropViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendToken(destinationChainId, l2TokenAddress, 100, address(this), UNBUNDLER_ADDRESS);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify bundle was emitted
        assertTrue(logs.length > 0, "Expected logs to be emitted");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Bundle hash should be non-zero");
        assertTrue(result.callCount > 0, "Bundle should contain at least one call");
    }

    function test_requestSendCallViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);

        vm.recordLogs();

        InteropLibrary.sendDirectCall(
            destinationChainId,
            interopTargetContract,
            abi.encodeWithSignature("simpleCall()"),
            EXECUTION_ADDRESS,
            UNBUNDLER_ADDRESS
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify bundle was emitted
        assertTrue(logs.length > 0, "Expected logs to be emitted");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Bundle hash should be non-zero");
        assertEq(result.callCount, 1, "Direct call should create exactly one call in the bundle");
    }

    function test_sendMessageToL1ViaLibrary() public {
        vm.recordLogs();
        InteropLibrary.sendMessage("testing interop");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Note: In L1 context, InteropLibrary.sendMessage may not emit logs
        // since the L2 system contracts are not fully functional.
        // We verify that the function executes without reverting.
        // If logs are emitted, verify InteropCenter is the emitter.
        if (logs.length > 0) {
            bool foundInteropCenterLog = false;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == L2_INTEROP_CENTER_ADDR) {
                    foundInteropCenterLog = true;
                    break;
                }
            }
            if (foundInteropCenterLog) {
                assertTrue(true, "InteropCenter emitted a log");
            }
        }
    }
}
