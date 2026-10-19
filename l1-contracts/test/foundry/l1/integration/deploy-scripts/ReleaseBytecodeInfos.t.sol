// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";
import {L2EcosystemContract} from "deploy-scripts/ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "deploy-scripts/ecosystem/CoreOnGatewayHelper.sol";
import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @dev Exposes the bytecode-info stage of `DeployCTM` on its own: it reads artifacts only.
contract ReleaseBytecodeInfosDeployer is DeployCTMScript {
    function cacheReleaseBytecodeInfos(string memory _scratchFile) external {
        _blakeBatchTmpFile = _scratchFile;
        _cacheReleaseBytecodeInfos();
    }

    function l2BytecodeInfoTable() external returns (bytes[] memory) {
        return getL2BytecodeInfoTable();
    }

    function l2SystemProxyBytecodeInfo() external returns (bytes memory) {
        return getL2SystemProxyBytecodeInfo();
    }

    function cachedBytecodeInfo(L2EcosystemContract _contract) external view returns (bytes memory) {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(_contract);
        return _cachedBytecodeInfo(fileName, contractName);
    }
}

/// @notice `DeployCTM` builds the release's L2 table from batch-hashed artifacts; the upgrade path
///         builds the same table hashing artifact by artifact. Both must agree row for row.
contract ReleaseBytecodeInfosTest is Test {
    ReleaseBytecodeInfosDeployer internal deployer;
    string internal scratchFile;

    function setUp() public {
        deployer = new ReleaseBytecodeInfosDeployer();
        scratchFile = string.concat(vm.projectRoot(), "/script-out/release-bytecode-infos-test-batch.txt");
    }

    function test_cachedTable_equalsPerArtifactTable() public {
        deployer.cacheReleaseBytecodeInfos(scratchFile);

        bytes[] memory cachedTable = deployer.l2BytecodeInfoTable();
        bytes[] memory perArtifactTable = SystemContractsProcessing.buildL2BytecodeInfoTable();
        assertEq(cachedTable.length, perArtifactTable.length, "table length");
        uint256 filledRows;
        for (uint256 i = 0; i < cachedTable.length; i++) {
            assertEq(cachedTable[i], perArtifactTable[i], "table row");
            if (cachedTable[i].length != 0) {
                ++filledRows;
            }
        }
        assertGt(filledRows, 0, "the table names artifacts");

        assertEq(
            deployer.l2SystemProxyBytecodeInfo(),
            SystemContractsProcessing.systemProxyBytecodeInfo(),
            "system proxy shell"
        );
        assertFalse(vm.exists(scratchFile), "the scratch file is removed");
    }

    /// @dev The beacon deployer has no table row; the genesis descriptor reads it from the cache.
    function test_cachesTheBeaconDeployer() public {
        deployer.cacheReleaseBytecodeInfos(scratchFile);

        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(
            L2EcosystemContract.UpgradeableBeaconDeployer
        );
        assertEq(
            deployer.cachedBytecodeInfo(L2EcosystemContract.UpgradeableBeaconDeployer),
            Utils.getZKOSBytecodeInfoForContract(fileName, contractName),
            "beacon deployer info"
        );
    }

    function test_revertWhen_tableReadBeforeCaching() public {
        vm.expectRevert("Bytecode info not cached");
        deployer.l2BytecodeInfoTable();
    }
}
