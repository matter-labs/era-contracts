// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {PubdataPricingMode, FeeParams} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeSetters} from "./_SharedBaseUpgradeSetters.t.sol";

contract DummyDefaultUpgrade is DefaultUpgrade, BaseUpgradeSetters {}

contract Upgrade_v1_4_1Test is BaseUpgrade {
    DummyDefaultUpgrade baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyDefaultUpgrade();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }
}
