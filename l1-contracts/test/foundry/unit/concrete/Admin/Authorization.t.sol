// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {FeeParams, PubdataPricingMode} from "solpp/zksync/Storage.sol";

contract AuthorizationTest is AdminTest {
    function test_SetPendingAdmin_RevertWhen_AdminNotGovernanceOwner() public {
        address newAdmin = address(0x1337);
        vm.prank(owner);
        vm.expectRevert(bytes.concat("1g"));
        proxyAsAdmin.setPendingAdmin(newAdmin);
    }

    function test_changeFeeParams() public {
        FeeParams memory newParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000,
            maxPubdataPerBatch: 1_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99,
            minimalL2GasPrice: 500_000_000
        });
        vm.prank(governor);
        proxyAsAdmin.changeFeeParams(newParams);

        bytes32 correctNewFeeParamsHash = keccak256(abi.encode(newParams));
        bytes32 currentFeeParamsHash = keccak256(abi.encode(proxyAsGettersMock.getFeeParams()));

        require(currentFeeParamsHash == correctNewFeeParamsHash, "Fee params were not changed correctly");
    }

    function test_changeFeeParams_RevertWhen_PriorityTxMaxPubdataHigherThanMaxPubdataPerBatch() public {
        FeeParams memory newParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000,
            maxPubdataPerBatch: 1_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 1_001,
            minimalL2GasPrice: 500_000_000
        });
        vm.prank(governor);
        vm.expectRevert(bytes.concat("n6"));
        proxyAsAdmin.changeFeeParams(newParams);
    }
}
