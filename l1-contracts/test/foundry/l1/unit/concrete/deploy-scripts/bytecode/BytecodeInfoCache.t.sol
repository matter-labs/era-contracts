// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BytecodeInfoCache} from "deploy-scripts/utils/bytecode/BytecodeInfoCache.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

contract BytecodeInfoCacheHarness is BytecodeInfoCache {
    function cacheBytecodeInfos(
        string[] memory _fileNames,
        string[] memory _contractNames,
        string memory _scratchFile
    ) external {
        _cacheBytecodeInfos(_fileNames, _contractNames, _scratchFile);
    }

    function cachedBytecodeInfo(
        string memory _fileName,
        string memory _contractName
    ) external view returns (bytes memory) {
        return _cachedBytecodeInfo(_fileName, _contractName);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract BytecodeInfoCacheTest is Test {
    BytecodeInfoCacheHarness internal cache;
    string internal scratchFile;

    function setUp() public {
        cache = new BytecodeInfoCacheHarness();
        scratchFile = string.concat(vm.projectRoot(), "/script-out/bytecode-info-cache-test-batch.txt");
    }

    /// @dev The batch-hashed info must equal the one `Utils` derives artifact by artifact.
    function test_cachedInfo_equalsPerArtifactInfo() public {
        (string[] memory fileNames, string[] memory contractNames) = _twoArtifacts();

        cache.cacheBytecodeInfos(fileNames, contractNames, scratchFile);

        for (uint256 i = 0; i < fileNames.length; i++) {
            bytes memory cached = cache.cachedBytecodeInfo(fileNames[i], contractNames[i]);
            assertEq(
                cached,
                Utils.getZKOSBytecodeInfoForContract(fileNames[i], contractNames[i]),
                "cached info differs from the per-artifact info"
            );

            bytes memory bytecode = BytecodeUtils.readDeployedBytecodeL1(fileNames[i], contractNames[i]);
            (, uint32 length, bytes32 observableHash) = ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(cached);
            assertEq(length, bytecode.length, "bytecode length");
            assertEq(observableHash, keccak256(bytecode), "observable bytecode hash");
        }
        assertFalse(vm.exists(scratchFile), "the scratch file is removed");
    }

    function test_revertWhen_artifactNotCached() public {
        (string[] memory fileNames, string[] memory contractNames) = _twoArtifacts();
        cache.cacheBytecodeInfos(fileNames, contractNames, scratchFile);

        vm.expectRevert("Bytecode info not cached");
        cache.cachedBytecodeInfo("L2ComplexUpgrader.sol", "L2ComplexUpgrader");
    }

    /// @dev The key is the (file, contract) pair, not the contract name alone.
    function test_revertWhen_fileNameDiffers() public {
        (string[] memory fileNames, string[] memory contractNames) = _twoArtifacts();
        cache.cacheBytecodeInfos(fileNames, contractNames, scratchFile);

        vm.expectRevert("Bytecode info not cached");
        cache.cachedBytecodeInfo("Other.sol", "EmptyContract");
    }

    function test_revertWhen_listLengthsDiffer() public {
        (string[] memory fileNames, ) = _twoArtifacts();
        string[] memory contractNames = new string[](1);
        contractNames[0] = "EmptyContract";

        vm.expectRevert("artifact list length mismatch");
        cache.cacheBytecodeInfos(fileNames, contractNames, scratchFile);
    }

    function _twoArtifacts() internal pure returns (string[] memory fileNames, string[] memory contractNames) {
        fileNames = new string[](2);
        contractNames = new string[](2);
        (fileNames[0], contractNames[0]) = ("EmptyContract.sol", "EmptyContract");
        (fileNames[1], contractNames[1]) = ("SystemContractProxy.sol", "SystemContractProxy");
    }
}
