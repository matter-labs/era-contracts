// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    SystemContractsProcessing,
    FixedAddressCoreContractDeployInfo,
    ERA_DEFERRED_CORE_CONTRACTS_COUNT
} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {CoreContract} from "deploy-scripts/ecosystem/CoreContract.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract EraForceDeploymentOrderingTest is Test {
    function test_EraDefersNTVButPublishesItsBytecode() public view {
        CoreContract[] memory sharedContracts = SystemContractsProcessing.getFixedAddressCoreContracts();
        FixedAddressCoreContractDeployInfo[] memory deployments = SystemContractsProcessing
            .getEraFixedAddressCoreContractDeployInfo();
        assertEq(deployments.length + ERA_DEFERRED_CORE_CONTRACTS_COUNT, sharedContracts.length);
        uint256 nextDeployment;
        for (uint256 i; i < sharedContracts.length; ++i) {
            if (sharedContracts[i] == CoreContract.L2NativeTokenVault) {
                continue;
            }
            assertEq(uint256(deployments[nextDeployment].id), uint256(sharedContracts[i]));
            assertTrue(deployments[nextDeployment].addr != L2_NATIVE_TOKEN_VAULT_ADDR);
            ++nextDeployment;
        }
        assertEq(nextDeployment, deployments.length);

        CoreContract[] memory dependencies = SystemContractsProcessing.getEraFactoryDependencyContracts();
        uint256 ntvDependencies;
        for (uint256 i; i < dependencies.length; ++i) {
            if (dependencies[i] == CoreContract.L2NativeTokenVault) {
                ++ntvDependencies;
            }
        }
        assertEq(ntvDependencies, ERA_DEFERRED_CORE_CONTRACTS_COUNT);
    }
}
