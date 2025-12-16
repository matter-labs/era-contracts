// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {InteropBundle, MessageInclusionProof} from "contracts/common/Messaging.sol";
import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

abstract contract L2InteropTestUtils is Test, SharedL2ContractDeployer {
    uint256 destinationChainId = 271;

    function extractAndExecuteSingleBundle(
        Vm.Log[] memory logs,
        uint256 _destinationChainId,
        address executionAddress
    ) internal {
        bytes memory data = extractFirstBundleFromLogs(logs);
        executeBundle(data, executionAddress, _destinationChainId);
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

    function executeBundle(bytes memory logsData, address executionAddress, uint256 _destinationChainId) internal {
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.chainId(_destinationChainId);
        vm.prank(executionAddress);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);
    }
}
