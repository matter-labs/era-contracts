// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";

/// @title LogFinder
/// @notice Utility library for querying Foundry `Vm.Log` arrays by event signature.
/// @dev Intended for use in Foundry tests via `using LogFinder for Vm.Log[]`.
///      All functions match logs by comparing `topics[0]` against the keccak256
///      hash of the provided event signature string.
library LogFinder {
    /// @notice Searches for the first log matching the given event signature.
    /// @dev Does not revert if no match is found; check the `found` return value.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string,
    ///        e.g. `"Transfer(address,address,uint256)"`.
    /// @return found True if a matching log was found, false otherwise.
    /// @return matchedLog The first matching `Vm.Log` entry. Undefined if `found` is false.
    function find(
        Vm.Log[] memory logs,
        string memory eventSignature
    ) internal pure returns (bool found, Vm.Log memory matchedLog) {
        bytes32 eventHash = keccak256(bytes(eventSignature));

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventHash) {
                return (true, logs[i]);
            }
        }
    }

    /// @notice Collects all logs matching the given event signature.
    /// @dev Uses two passes over the logs array: one to count matches, one to
    ///      populate the result. This avoids dynamic memory resizing since Solidity
    ///      does not support `push` on memory arrays.
    ///      Returns an empty array if no matches are found.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string,
    ///        e.g. `"Transfer(address,address,uint256)"`.
    /// @return matchedLogs An array of all `Vm.Log` entries whose `topics[0]`
    ///         matches the keccak256 hash of `eventSignature`.
    function findAll(
        Vm.Log[] memory logs,
        string memory eventSignature
    ) internal pure returns (Vm.Log[] memory matchedLogs) {
        bytes32 eventHash = keccak256(bytes(eventSignature));

        uint256 count = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventHash) {
                count++;
            }
        }

        matchedLogs = new Vm.Log[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventHash) {
                matchedLogs[idx++] = logs[i];
            }
        }
    }

    /// @notice Returns the first log matching the given event signature, reverting if none is found.
    /// @dev Use this when the event being emitted is a hard requirement of the test.
    ///      Reverts with the event signature and `: event not found` as the reason.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string,
    ///        e.g. `"Transfer(address,address,uint256)"`.
    /// @return matchedLog The first matching `Vm.Log` entry.
    function requireOne(
        Vm.Log[] memory logs,
        string memory eventSignature
    ) internal pure returns (Vm.Log memory matchedLog) {
        (bool found, Vm.Log memory log) = find(logs, eventSignature);
        require(found, string.concat(eventSignature, ": event not found"));
        return log;
    }

    /// @notice Asserts that exactly `expectedCount` logs match the given event signature.
    /// @dev Reverts if the number of matching logs differs from `expectedCount`.
    ///      Reverts with the event signature and `: unexpected log count` as the reason.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string,
    ///        e.g. `"Transfer(address,address,uint256)"`.
    /// @param expectedCount The exact number of matching logs expected.
    /// @return matchedLogs An array of all matching `Vm.Log` entries.
    function requireCount(
        Vm.Log[] memory logs,
        string memory eventSignature,
        uint256 expectedCount
    ) internal pure returns (Vm.Log[] memory matchedLogs) {
        matchedLogs = findAll(logs, eventSignature);
        require(matchedLogs.length == expectedCount, string.concat(eventSignature, ": unexpected log count"));
    }

    /// @notice Asserts that at least `minCount` logs match the given event signature.
    /// @dev Reverts if the number of matching logs is less than `minCount`.
    ///      Reverts with the event signature and `: insufficient log count` as the reason.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string,
    ///        e.g. `"Transfer(address,address,uint256)"`.
    /// @param minCount The minimum number of matching logs required.
    /// @return matchedLogs An array of all matching `Vm.Log` entries.
    function requireAtLeast(
        Vm.Log[] memory logs,
        string memory eventSignature,
        uint256 minCount
    ) internal pure returns (Vm.Log[] memory matchedLogs) {
        matchedLogs = findAll(logs, eventSignature);
        require(matchedLogs.length >= minCount, string.concat(eventSignature, ": insufficient log count"));
    }

    /// @notice Collects all logs matching the given event signature emitted by a specific contract.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string.
    /// @param emitter The contract address that must have emitted the log.
    /// @return matchedLogs All matching `Vm.Log` entries from the specified emitter.
    function findAllFrom(
        Vm.Log[] memory logs,
        string memory eventSignature,
        address emitter
    ) internal pure returns (Vm.Log[] memory matchedLogs) {
        Vm.Log[] memory candidates = findAll(logs, eventSignature);

        uint256 count = 0;
        for (uint256 i = 0; i < candidates.length; i++) {
            if (candidates[i].emitter == emitter) count++;
        }

        matchedLogs = new Vm.Log[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < candidates.length; i++) {
            if (candidates[i].emitter == emitter) matchedLogs[idx++] = candidates[i];
        }
    }

    /// @notice Returns the first log matching the given event signature from a specific emitter,
    ///         reverting if none is found.
    /// @param logs The recorded logs array from `vm.getRecordedLogs()`.
    /// @param eventSignature The canonical event signature string.
    /// @param emitter The contract address that must have emitted the log.
    /// @return matchedLog The first matching `Vm.Log` entry.
    function requireOneFrom(
        Vm.Log[] memory logs,
        string memory eventSignature,
        address emitter
    ) internal pure returns (Vm.Log memory matchedLog) {
        Vm.Log[] memory candidates = findAllFrom(logs, eventSignature, emitter);
        require(candidates.length > 0, string.concat(eventSignature, ": event not found from emitter"));
        return candidates[0];
    }
}
