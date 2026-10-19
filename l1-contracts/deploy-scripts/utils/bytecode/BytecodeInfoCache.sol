// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

import {Blake2s} from "./Blake2s.sol";
import {BytecodeUtils} from "./BytecodeUtils.s.sol";

/// @notice Caches the ZKsync OS bytecode infos of L1 artifacts, keyed by artifact identity, so a
///         script that needs many of them hashes them all in one {Blake2s.hashBatch}.
abstract contract BytecodeInfoCache {
    /// @dev ZKsync OS bytecode infos keyed by {_bytecodeInfoKey}.
    mapping(bytes32 artifactKey => bytes bytecodeInfo) private _bytecodeInfoCache;

    /// @notice Reads each artifact's deployed bytecode and caches its ZKsync OS bytecode info.
    /// @param _fileNames The artifacts' source file names, e.g. `EmptyContract.sol`.
    /// @param _contractNames The artifacts' contract names, index-aligned with `_fileNames`.
    /// @param _scratchFile The file {Blake2s.hashBatch} hands the batch over through.
    function _cacheBytecodeInfos(
        string[] memory _fileNames,
        string[] memory _contractNames,
        string memory _scratchFile
    ) internal {
        require(_fileNames.length == _contractNames.length, "artifact list length mismatch");
        bytes[] memory bytecodes = new bytes[](_fileNames.length);
        for (uint256 i = 0; i < _fileNames.length; i++) {
            bytecodes[i] = BytecodeUtils.readDeployedBytecodeL1(_fileNames[i], _contractNames[i]);
        }

        bytes32[] memory blakeHashes = Blake2s.hashBatch(bytecodes, _scratchFile);

        for (uint256 i = 0; i < _fileNames.length; i++) {
            _bytecodeInfoCache[_bytecodeInfoKey(_fileNames[i], _contractNames[i])] = ZKSyncOSBytecodeInfo
                .encodeZKSyncOSBytecodeInfo(blakeHashes[i], uint32(bytecodes[i].length), keccak256(bytecodes[i]));
        }
    }

    /// @notice The ZKsync OS bytecode info of an artifact {_cacheBytecodeInfos} cached.
    /// @param _fileName The artifact's source file name.
    /// @param _contractName The artifact's contract name.
    function _cachedBytecodeInfo(
        string memory _fileName,
        string memory _contractName
    ) internal view returns (bytes memory bytecodeInfo) {
        bytecodeInfo = _bytecodeInfoCache[_bytecodeInfoKey(_fileName, _contractName)];
        require(bytecodeInfo.length != 0, "Bytecode info not cached");
    }

    function _bytecodeInfoKey(string memory _fileName, string memory _contractName) private pure returns (bytes32) {
        return keccak256(abi.encode(_fileName, _contractName));
    }
}
