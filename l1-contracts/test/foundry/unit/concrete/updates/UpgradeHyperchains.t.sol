// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {UpgradeHyperchains} from "contracts/upgrades/UpgradeHyperchains.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeSetters} from "./_SharedBaseUpgradeSetters.t.sol";

contract DummyUpgradeHyperchains is UpgradeHyperchains, BaseUpgradeSetters {}

contract UpgradeHyperchainsTest is BaseUpgrade {
    DummyUpgradeHyperchains baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyUpgradeHyperchains();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_revertWhen_ChainIdIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(
            0,
            makeAddr("brighehub"),
            makeAddr("stateTransitionManager"),
            makeAddr("sharedBridgeAddress")
        );
        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 1"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_BridgehubAddressIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(
            1,
            address(0),
            makeAddr("stateTransitionManager"),
            makeAddr("sharedBridgeAddress")
        );
        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 2"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_StateTransitionManagerIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(
            1,
            makeAddr("brighehub"),
            address(0),
            makeAddr("sharedBridgeAddress")
        );
        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 3"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_SharedBridgeAddressIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(
            1,
            makeAddr("brighehub"),
            makeAddr("stateTransitionManager"),
            address(0)
        );
        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 4"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }
}
