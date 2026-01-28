// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {InteropBundle, MessageInclusionProof, BundleStatus, CallStatus} from "contracts/common/Messaging.sol";
import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";

/// @notice Struct to hold bundle execution result for assertions
struct BundleExecutionResult {
    bytes32 bundleHash;
    uint256 callCount;
    uint256 destinationChainId;
}

abstract contract L2InteropTestUtils is Test, SharedL2ContractDeployer {
    uint256 destinationChainId = 271;

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
    /// @param result The bundle execution result to verify
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
}
