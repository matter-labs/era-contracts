// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";

import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

contract PrecommittingTest is ExecutorTest {
    uint256 constant TOTAL_TRANSACTIONS = 100;
    uint256 batchNumber = 1;
    uint256 l2BlockNumber = 18;

    function precommitData() internal view returns (bytes memory) {
        bytes memory packedTxsCommitments = hex"";
        for (uint i = 0; i < TOTAL_TRANSACTIONS; ++i) {
            packedTxsCommitments = bytes.concat(
                packedTxsCommitments,
                abi.encodePacked(keccak256(abi.encode(i)), uint8(i % 3 == 0 ? 0 : 1))
            );
        }

        IExecutor.PrecommitInfo memory precommitInfo = IExecutor.PrecommitInfo({
            packedTxsCommitments: packedTxsCommitments,
            untrustedLastL2BlockNumberHint: l2BlockNumber
        });

        return abi.encodePacked(BatchDecoder.SUPPORTED_ENCODING_VERSION, abi.encode(precommitInfo));
    }

    function test_SuccessfullyPrecommit() public {
        vm.prank(validator);
        vm.recordLogs();

        committer.precommitSharedBridge(address(0), batchNumber, precommitData());

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BatchPrecommitmentSet(uint256,uint256,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(batchNumber));
        assertEq(entries[0].topics[2], bytes32(l2BlockNumber));
    }

    // For accurate measuring of gas usage via snapshot cheatcodes, isolation mode has to be enabled.
    /// forge-config: default.isolate = true
    function test_MeasureGas() public {
        vm.prank(validator);
        validatorTimelock.precommitSharedBridge(address(executor), batchNumber, precommitData());
        vm.snapshotGasLastCall("Executor", "precommit");
    }
}
