// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

contract PrecommittingTest is ExecutorTest {
    function test_SuccessfullyPrecommit() public {
        uint256 totalTransactions = 1;
        uint256 batchNumber = 1;
        uint256 miniblockNumber = 1;

        IExecutor.TransactionStatusCommitment[] memory txs = new IExecutor.TransactionStatusCommitment[](totalTransactions);
        for (uint i = 0; i < totalTransactions; ++i) {
            txs[i] = IExecutor.TransactionStatusCommitment({
                txHash: keccak256(abi.encode(i)),
                status: i % 3 != 0
            });
        }

        IExecutor.PrecommitInfo memory precommitInfo = IExecutor.PrecommitInfo({
            txs: txs,
            untrustedLastMiniblockNumberHint: miniblockNumber
        });

        bytes memory precommitData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION,
            abi.encode(precommitInfo)
        );

        vm.prank(validator);
        vm.recordLogs();
        executor.precommitSharedBridge(block.chainid, batchNumber, precommitData);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BatchPrecommitmentSet(uint256,uint256,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(batchNumber));
        assertEq(entries[0].topics[2], bytes32(miniblockNumber));
    }
}
