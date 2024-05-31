// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseZkSyncUpgradeGenesis} from "contracts/upgrades/BaseZkSyncUpgradeGenesis.sol";
import {ProtocolVersionShouldBeGreater, ProtocolVersionDeltaTooLarge, PreviousUpgradeNotFinalized, PreviousUpgradeBatchNotCleared} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {MAX_ALLOWED_PROTOCOL_VERSION_DELTA} from "contracts/common/Config.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummytBaseZkSyncUpgradeGenesis is BaseZkSyncUpgradeGenesis, BaseUpgradeUtils {}

contract BaseZkSyncUpgradeGenesisTest is BaseUpgrade {
    DummytBaseZkSyncUpgradeGenesis baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummytBaseZkSyncUpgradeGenesis();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_revertWhen_UpgradeIsNotReady(uint256 upgradeTimestamp) public {
        vm.assume(upgradeTimestamp > block.timestamp);

        proposedUpgrade.upgradeTimestamp = upgradeTimestamp;

        vm.expectRevert(bytes("Upgrade is not ready yet"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_ProtocolVersionShouldBeGreater(
        uint256 currentProtocolVersion,
        uint256 newProtocolVersion
    ) public {
        baseZkSyncUpgrade.setProtocolVersion(currentProtocolVersion);

        vm.assume(newProtocolVersion <= currentProtocolVersion && newProtocolVersion > 0);

        proposedUpgrade.newProtocolVersion = newProtocolVersion;

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolVersionShouldBeGreater.selector, currentProtocolVersion, newProtocolVersion)
        );
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_ProtocolVersionDeltaTooLarge(uint256 newProtocolVersion) public {
        vm.assume(newProtocolVersion > MAX_ALLOWED_PROTOCOL_VERSION_DELTA);

        proposedUpgrade.newProtocolVersion = newProtocolVersion;

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionDeltaTooLarge.selector,
                newProtocolVersion,
                MAX_ALLOWED_PROTOCOL_VERSION_DELTA
            )
        );
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_PreviousUpgradeNotFinalized() public {
        baseZkSyncUpgrade.setL2SystemContractsUpgradeTxHash(bytes32(bytes("txHash")));

        vm.expectRevert(PreviousUpgradeNotFinalized.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_PreviousUpgradeBatchNotCleared(uint256 batchNumber) public {
        vm.assume(batchNumber > 0);

        baseZkSyncUpgrade.setL2SystemContractsUpgradeBatchNumber(batchNumber);

        vm.expectRevert(PreviousUpgradeBatchNotCleared.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }
}
