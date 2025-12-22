// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {InteropBundle, MessageInclusionProof, CallStatus} from "contracts/common/Messaging.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropUnbundleTestAbstract is L2InteropTestUtils {
    function test_unbundleBundleViaReceiveMessage() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100, false);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        bytes memory logsData = extractFirstBundleFromLogs(logs1);
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);

        vm.chainId(destinationChainId);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        L2_INTEROP_HANDLER.verifyBundle(bundle, proof);
        vm.chainId(originalChainId);

        vm.recordLogs();

        CallStatus[] memory callStatuses = new CallStatus[](1);
        callStatuses[0] = CallStatus.Executed;
        vm.prank(UNBUNDLER_ADDRESS);
        InteropLibrary.sendDirectCall(
            destinationChainId,
            L2_INTEROP_HANDLER_ADDR,
            abi.encodeCall(L2_INTEROP_HANDLER.unbundleBundle, (originalChainId, bundle, callStatuses)),
            UNBUNDLER_ADDRESS,
            UNBUNDLER_ADDRESS
        );
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs2, destinationChainId, UNBUNDLER_ADDRESS);
    }
}
