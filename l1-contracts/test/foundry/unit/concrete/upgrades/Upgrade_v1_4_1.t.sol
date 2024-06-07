// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrade_v1_4_1} from "contracts/upgrades/Upgrade_v1_4_1.sol";
import {PubdataPricingMode, FeeParams} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {ZkSyncHyperchainStorage} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyUpgrade_v1_4_1 is Upgrade_v1_4_1, BaseUpgradeUtils {
    function updateFeeParams(FeeParams memory _newFeeParams) public {
        changeFeeParams(_newFeeParams);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}

contract Upgrade_v1_4_1Test is BaseUpgrade {
    DummyUpgrade_v1_4_1 baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyUpgrade_v1_4_1();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function test_revertWhen_MaxPubdataPerBatchIsLowerThanPriorityTxMaxPubdata() public {
        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 0,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 250_000_000
        });

        vm.expectRevert(bytes("n6"));
        baseZkSyncUpgrade.updateFeeParams(feeParams);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);

        FeeParams memory feeParams = baseZkSyncUpgrade.getFeeParams();
        assertEq(feeParams.batchOverheadL1Gas, 1_000_000);
        assertEq(feeParams.maxPubdataPerBatch, 120_000);
        assertEq(feeParams.maxL2GasPerBatch, 80_000_000);
        assertEq(feeParams.priorityTxMaxPubdata, 99_000);
        assertEq(feeParams.minimalL2GasPrice, 250_000_000);
    }
}
