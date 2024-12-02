// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseZkSyncUpgradeGenesis} from "contracts/upgrades/BaseZkSyncUpgradeGenesis.sol";
import {ProtocolVersionTooSmall, ProtocolVersionDeltaTooLarge, PreviousUpgradeNotFinalized, PreviousUpgradeBatchNotCleared, ProtocolMajorVersionNotZero} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {MAX_ALLOWED_MINOR_VERSION_DELTA} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyBaseZkSyncUpgradeGenesis is BaseZkSyncUpgradeGenesis, BaseUpgradeUtils {}

contract BaseZkSyncUpgradeGenesisTest is BaseUpgrade {
    DummyBaseZkSyncUpgradeGenesis baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyBaseZkSyncUpgradeGenesis();

        _prepareProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    // New protocol version is not greater than the current one
    function test_revertWhen_newProtocolVersionIsNotGreaterThanTheCurrentOne(
        uint32 currentProtocolVersion,
        uint32 newProtocolVersion
    ) public {
        vm.assume(newProtocolVersion < currentProtocolVersion && newProtocolVersion > 0);

        uint256 semVerCurrentProtocolVersion = SemVer.packSemVer(0, currentProtocolVersion, 0);
        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        baseZkSyncUpgrade.setProtocolVersion(semVerCurrentProtocolVersion);

        proposedUpgrade.newProtocolVersion = semVerNewProtocolVersion;

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Major version is not zero
    function test_revertWhen_MajorVersionIsNotZero() public {
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(1, 0, 0));

        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(1, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(ProtocolMajorVersionNotZero.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // New major version is not zero
    function test_revertWhen_MajorMustAlwaysBeZero(uint32 newProtocolVersion) public {
        vm.assume(newProtocolVersion > 0);

        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(1, newProtocolVersion, 0);

        vm.expectRevert(abi.encodeWithSelector(ProtocolMajorVersionNotZero.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Protocol version difference is too big
    function test_revertWhen_tooBigProtocolVersionDifference(
        uint32 newProtocolVersion,
        uint8 oldProtocolVersion
    ) public {
        vm.assume(newProtocolVersion > MAX_ALLOWED_MINOR_VERSION_DELTA + oldProtocolVersion + 1);
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, oldProtocolVersion, 0));
        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        proposedUpgrade.newProtocolVersion = semVerNewProtocolVersion;

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionDeltaTooLarge.selector,
                newProtocolVersion - oldProtocolVersion,
                MAX_ALLOWED_MINOR_VERSION_DELTA
            )
        );
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Previous upgrade has not been finalized
    function test_revertWhen_previousUpgradeHasNotBeenFinalized() public {
        bytes32 l2SystemContractsUpgradeTxHash = bytes32(bytes("txHash"));
        baseZkSyncUpgrade.setL2SystemContractsUpgradeTxHash(l2SystemContractsUpgradeTxHash);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, l2SystemContractsUpgradeTxHash));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Batch number of the previous upgrade has not been cleaned
    function test_revertWhen_batchNumberOfThePreviousUpgradeHasNotBeenCleaned(uint256 batchNumber) public {
        vm.assume(batchNumber > 0);

        baseZkSyncUpgrade.setL2SystemContractsUpgradeBatchNumber(batchNumber);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeBatchNotCleared.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessUpgrade() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }
}
