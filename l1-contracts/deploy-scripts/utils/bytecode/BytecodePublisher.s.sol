// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors, reason-string

import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/Script.sol";

import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {Utils} from "../Utils.sol";

/// @notice Result of publishing and processing factory dependencies.
struct PublishFactoryDepsResult {
    /// @dev Factory dep hashes for the upgrade transaction.
    ///      Era: `L2ContractHelper.hashL2Bytecode` (padded-bytes L2 hash).
    ///      ZKsyncOS: keccak256 of the raw bytecode — the same key
    ///      `BytecodesSupplier` uses for `evmPublishingBlock` and the topic1
    ///      of `EVMBytecodePublished`, so the server can filter events by
    ///      topic1 directly and load matching preimages. The server then
    ///      re-hashes each preimage with Blake2s256 when it inserts into its
    ///      own store (the ZKsyncOS-specific lookup key the VM queries by).
    uint256[] factoryDepsHashes;
}

library BytecodePublisher {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice Maximal size of bytecodes' batch to be published at once
    uint256 constant MAX_BATCH_SIZE = 126_000;

    /// @notice Publishes bytecodes in batches, each not exceeding `MAX_BATCH_SIZE`
    /// @param bytecodesSupplier The BytecodesSupplier contract
    /// @param bytecodes The array of bytecodes to publish
    /// @param isEVM If true, publish as EVM bytecodes (using keccak256 hash), otherwise as Era bytecodes
    function publishBytecodesInBatches(
        BytecodesSupplier bytecodesSupplier,
        bytes[] memory bytecodes,
        bool isEVM
    ) internal {
        uint256 totalBytecodes = bytecodes.length;
        require(totalBytecodes > 0, "No bytecodes to publish");

        uint256 currentBatchSize = 0;
        uint256 batchStartIndex = 0;

        bytes[] memory toPublish = new bytes[](bytecodes.length);
        uint256 toPublishPtr = 0;

        for (uint256 i = 0; i < totalBytecodes; i++) {
            bytes32 hash = isEVM
                ? ZKSyncOSBytecodeInfo.hashEVMBytecode(bytecodes[i])
                : L2ContractHelper.hashL2Bytecode(bytecodes[i]);
            uint256 publishedBlock = isEVM
                ? bytecodesSupplier.evmPublishingBlock(hash)
                : bytecodesSupplier.publishingBlock(hash);

            if (publishedBlock != 0) {
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
                _publishBatch(bytecodesSupplier, currentBatch, isEVM);

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
            _publishBatch(bytecodesSupplier, lastBatch, isEVM);
        }
    }

    /// @notice Publishes Era bytecodes in batches, each not exceeding `MAX_BATCH_SIZE`
    /// @param bytecodesSupplier The BytecodesSupplier contract
    /// @param bytecodes The array of bytecodes to publish
    function publishEraBytecodesInBatches(BytecodesSupplier bytecodesSupplier, bytes[] memory bytecodes) internal {
        publishBytecodesInBatches(bytecodesSupplier, bytecodes, false);
    }

    /// @notice Publishes EVM bytecodes in batches, each not exceeding `MAX_BATCH_SIZE`
    /// @param bytecodesSupplier The BytecodesSupplier contract
    /// @param bytecodes The array of bytecodes to publish
    function publishEVMBytecodesInBatches(BytecodesSupplier bytecodesSupplier, bytes[] memory bytecodes) internal {
        publishBytecodesInBatches(bytecodesSupplier, bytecodes, true);
    }

    /// @notice Internal function to publish a single batch of bytecodes
    /// @param bytecodesSupplier The BytecodesSupplier contract
    /// @param batch The batch of bytecodes to publish
    /// @param isEVM If true, publish as EVM bytecodes, otherwise as Era bytecodes
    function _publishBatch(BytecodesSupplier bytecodesSupplier, bytes[] memory batch, bool isEVM) internal {
        vm.broadcast(Utils.getBroadcasterAddress());
        if (isEVM) {
            bytecodesSupplier.publishEVMBytecodes(batch);
        } else {
            bytecodesSupplier.publishEraBytecodes(batch);
        }
    }

    /// @notice Publish bytecodes and compute factory dependency hashes in one call.
    ///         Era: publishes bytecodes, computes L2 bytecode hashes, returns populated result.
    ///         EVM bytecodes: publishes bytecodes, returns empty array (no factory deps concept).
    function publishAndProcessFactoryDeps(
        bool _isEVMBytecode,
        BytecodesSupplier _supplier,
        bytes[] memory _allDeps
    ) internal returns (PublishFactoryDepsResult memory result) {
        if (_isEVMBytecode) {
            publishEVMBytecodesInBatches(_supplier, _allDeps);
        } else {
            publishEraBytecodesInBatches(_supplier, _allDeps);
        }

        uint256 depsLen = _allDeps.length;
        require(depsLen <= 64, "Too many deps");

        result.factoryDepsHashes = new uint256[](depsLen);
        if (_isEVMBytecode) {
            // Use the EVM-native keccak256 here. It matches the key
            // `BytecodesSupplier.evmPublishingBlock` uses and the indexed
            // topic1 of `EVMBytecodePublished`, so the server can filter
            // events by topic directly. Server-side translation into the
            // Blake2s256 store key happens after the event payload arrives,
            // keeping the ZKsyncOS-specific hash layer off the contract.
            for (uint256 i = 0; i < depsLen; i++) {
                result.factoryDepsHashes[i] = uint256(keccak256(_allDeps[i]));
            }
            return result;
        }

        for (uint256 i = 0; i < depsLen; i++) {
            result.factoryDepsHashes[i] = uint256(L2ContractHelper.hashL2Bytecode(_allDeps[i]));
        }
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
