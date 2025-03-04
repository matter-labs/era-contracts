// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/Script.sol";

import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";

library BytecodePublisher {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice Maximal size of bytecodes' batch to be published at once
    uint256 constant MAX_BATCH_SIZE = 126_000;

    /// @notice Publishes bytecodes in batches, each not exceeding `MAX_BATCH_SIZE`
    /// @param bytecodes The array of bytecodes to publish
    function publishBytecodesInBatches(BytecodesSupplier bytecodesSupplier, bytes[] memory bytecodes) internal {
        uint256 totalBytecodes = bytecodes.length;
        require(totalBytecodes > 0, "No bytecodes to publish");

        uint256 currentBatchSize = 0;
        uint256 batchStartIndex = 0;

        bytes[] memory toPublish = new bytes[](bytecodes.length);
        uint256 toPublishPtr = 0;

        for (uint256 i = 0; i < totalBytecodes; i++) {
            bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecodes[i]);
            if (bytecodesSupplier.publishingBlock(hash) != 0) {
                console.log("The following bytecode has already been published:");
                console.logBytes32(hash);
                continue;
            } else {
                console.log("Publishing the following bytecode:");
                console.logBytes32(hash);
            }

            uint256 bytecodeSize = bytecodes[i].length;

            if (bytecodeSize > MAX_BATCH_SIZE) {
                console.log("The following bytecode is too large ", i);
                console.log("Its size ", bytecodeSize);

                revert("Bytecode is not publishable");
            }

            // Check if adding this bytecode exceeds the MAX_BATCH_SIZE
            if (currentBatchSize + bytecodeSize > MAX_BATCH_SIZE) {
                // Publish the current batch
                bytes[] memory currentBatch = slice(toPublish, 0, toPublishPtr);
                _publishBatch(bytecodesSupplier, currentBatch);

                // Reset for the next batch
                batchStartIndex = i;
                toPublishPtr = 0;
                currentBatchSize = 0;
            }

            currentBatchSize += bytecodeSize;
            toPublish[toPublishPtr++] = bytecodes[i];
        }

        // Publish the last batch if any
        if (toPublishPtr != 0) {
            bytes[] memory lastBatch = slice(toPublish, 0, toPublishPtr);
            _publishBatch(bytecodesSupplier, lastBatch);
        }
    }

    /// @notice Internal function to publish a single batch and emit an event
    /// @param batch The batch of bytecodes to publish
    function _publishBatch(BytecodesSupplier bytecodesSupplier, bytes[] memory batch) internal {
        vm.broadcast();
        bytecodesSupplier.publishBytecodes(batch);
    }

    /// @notice Slices a bytes[][] array from start index to end index (exclusive)
    /// @param array The original bytes[][] array
    /// @param start The starting index (inclusive)
    /// @param end The ending index (exclusive)
    /// @return sliced The sliced bytes[][] array
    function slice(bytes[] memory array, uint256 start, uint256 end) internal pure returns (bytes[] memory sliced) {
        require(start <= end && end <= array.length, "Invalid slice indices");
        sliced = new bytes[](end - start);
        for (uint256 i = start; i < end; i++) {
            sliced[i - start] = array[i];
        }
    }
}
