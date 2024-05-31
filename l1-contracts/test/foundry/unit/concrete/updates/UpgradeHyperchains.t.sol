// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {UpgradeHyperchains} from "contracts/upgrades/UpgradeHyperchains.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyUpgradeHyperchains is UpgradeHyperchains, BaseUpgradeUtils {}

contract UpgradeHyperchainsTest is BaseUpgrade {
    DummyUpgradeHyperchains baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyUpgradeHyperchains();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_revertWhen_ChainIdIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(0, bridgeHub, stateTransitionManager, sharedBridge);

        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 1"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_BridgehubAddressIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(chainId, address(0), stateTransitionManager, sharedBridge);

        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 2"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_StateTransitionManagerIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(1, bridgeHub, address(0), sharedBridge);

        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 3"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_revertWhen_SharedBridgeAddressIsZero() public {
        bytes memory postUpgradeCalldata = abi.encode(1, bridgeHub, stateTransitionManager, address(0));

        proposedUpgrade.postUpgradeCalldata = postUpgradeCalldata;

        vm.expectRevert(bytes("UpgradeHyperchain: 4"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);

        assertEq(baseZkSyncUpgrade.getChainId(), chainId);
        assertEq(baseZkSyncUpgrade.getBridgeHub(), bridgeHub);
        assertEq(baseZkSyncUpgrade.getStateTransitionManager(), stateTransitionManager);
        assertEq(baseZkSyncUpgrade.getSharedBridge(), sharedBridge);
    }
}
