// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseZkSyncUpgradeGenesis} from "contracts/upgrades/BaseZkSyncUpgradeGenesis.sol";
import {ProtocolVersionShouldBeGreater, ProtocolVersionDeltaTooLarge, PreviousUpgradeNotFinalized, PreviousUpgradeBatchNotCleared} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {MAX_ALLOWED_PROTOCOL_VERSION_DELTA} from "contracts/common/Config.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeSetters} from "./_SharedBaseUpgradeSetters.t.sol";

contract DummytBaseZkSyncUpgradeGenesis is BaseZkSyncUpgradeGenesis, BaseUpgradeSetters {}

contract BaseZkSyncUpgradeGenesisTest is BaseUpgrade {
    DummytBaseZkSyncUpgradeGenesis baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummytBaseZkSyncUpgradeGenesis();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_revertWhen_UpgradeIsNotReady() public {
        proposedUpgrade.upgradeTimestamp = block.timestamp + 1;

        vm.expectRevert(bytes("Upgrade is not ready yet"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_ProtocolVersionShouldBeGreater() public {
        baseZkSyncUpgrade.setProtocolVersion(2);

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionShouldBeGreater.selector, 2, 1));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_ProtocolVersionDeltaTooLarge() public {
        proposedUpgrade.newProtocolVersion = 101;

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolVersionDeltaTooLarge.selector, 101, MAX_ALLOWED_PROTOCOL_VERSION_DELTA)
        );
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_PreviousUpgradeNotFinalized() public {
        baseZkSyncUpgrade.setL2SystemContractsUpgradeTxHash(bytes32(bytes("txHash")));

        vm.expectRevert(PreviousUpgradeNotFinalized.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_PreviousUpgradeBatchNotCleared() public {
        baseZkSyncUpgrade.setL2SystemContractsUpgradeBatchNumber(1);

        vm.expectRevert(PreviousUpgradeBatchNotCleared.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }
}
