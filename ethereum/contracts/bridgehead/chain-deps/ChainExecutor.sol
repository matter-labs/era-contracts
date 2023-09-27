// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./ChainBase.sol";
import {EMPTY_STRING_KECCAK} from "../Config.sol";
import "../chain-interfaces/IChainExecutor.sol";
import "../libraries/PriorityQueue.sol";
import "../../common/libraries/UncheckedMath.sol";
// import "../../common/libraries/UnsafeBytes.sol";
import "../../common/libraries/L2ContractHelper.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR} from "../../common/L2ContractAddresses.sol";

/// @title zkSync Executor contract capable of processing events emitted in the zkSync protocol.
/// @author Matter Labs
contract ChainExecutor is IChainExecutor, ChainBase {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /// @notice Commit block
    function executeBlocks() external override nonReentrant {}

    /// @return concatHash , Returns the concatenated Hash of operations from the priority queue
    function collectOperationsFromPriorityQueue(
        uint256 _nPriorityOps
    ) external override nonReentrant onlyProofChain returns (bytes32 concatHash) {
        concatHash = EMPTY_STRING_KECCAK;
        require(_nPriorityOps <= chainStorage.priorityQueue.getSize(), "g1");

        for (uint256 i = 0; i < _nPriorityOps; i = i.uncheckedInc()) {
            PriorityOperation memory priorityOp = chainStorage.priorityQueue.popFront();
            concatHash = keccak256(abi.encode(concatHash, priorityOp.canonicalTxHash));
        }
    }

    /// @notice Adding L2 Logs from the proof system
    function addL2Logs(uint256 _index, bytes32 _l2LogsRootHashes) external override nonReentrant onlyProofChain {
        chainStorage.l2LogsRootHashes[_index] = _l2LogsRootHashes;
    }
}
