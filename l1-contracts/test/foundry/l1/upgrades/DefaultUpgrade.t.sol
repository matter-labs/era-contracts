// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyDefaultUpgrade is DefaultUpgrade, BaseUpgradeUtils {}

contract DefaultUpgradeTest is BaseUpgrade {
    DummyDefaultUpgrade baseZkSyncUpgrade;
    address mockChainTypeManager = makeAddr("mockChainTypeManager");
    address mockVerifier = makeAddr("mockVerifier");

    function setUp() public {
        baseZkSyncUpgrade = new DummyDefaultUpgrade();

        _prepareProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);

        // Set up CTM for verifier lookup
        baseZkSyncUpgrade.setChainTypeManager(mockChainTypeManager);
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_SuccessUpgrade() public {
        bytes32 result = baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        // verifier is now fetched from CTM, not from proposedUpgrade
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }
}
