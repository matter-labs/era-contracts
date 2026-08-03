// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreContract} from "deploy-scripts/ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "deploy-scripts/ecosystem/CoreOnGatewayHelper.sol";
import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {ContractsBytecodesLib} from "deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice The ZKsync-OS-only contracts are force-deployed from their own list, so their bytecodes have to
/// be merged into the ZKsync OS factory dependencies separately. A force deployment whose preimage is not
/// published makes the L2 upgrade transaction panic on the first access to the missing code, which no
/// fixture that installs bytecode itself (`vm.etch`, `anvil_setCode`) would notice.
contract ZKsyncOSOnlyContractsTest is Test {
    function test_forceDeploymentsIncludeTheZKsyncOSOnlyContracts() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseZKsyncOSForceDeployments();

        assertTrue(_containsAddress(deployments, L2_INTEROP_COMMITMENT_TREE_ADDR), "commitment tree missing");
        assertTrue(_containsAddress(deployments, L2_ATOMIC_FLOW_MANAGER_ADDR), "flow manager missing");
    }

    function test_zkSyncOSFactoryDependenciesCoverEveryForceDeployment() public {
        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, new CoreContract[](0));

        // Every bytecode the force-deploy path materializes must be published, or the sequencer has no
        // preimage for it.
        CoreContract[] memory zksyncOSOnlyContracts = SystemContractsProcessing.getZKsyncOSOnlyContracts();
        for (uint256 i = 0; i < zksyncOSOnlyContracts.length; ++i) {
            bytes32 expected = keccak256(_deployedBytecode(zksyncOSOnlyContracts[i]));
            assertEq(_countBytecode(factoryDeps, expected), 1, "bytecode not published exactly once");
        }
    }

    function test_eraForceDeploymentsExcludeTheZKsyncOSOnlyContracts() public {
        // Era chains have no atomic interop — and no IMT-aware bootloader — so these must not be deployed
        // onto them.
        CoreContract[] memory fixedAddressCoreContracts = SystemContractsProcessing.getFixedAddressCoreContracts();
        CoreContract[] memory zksyncOSOnlyContracts = SystemContractsProcessing.getZKsyncOSOnlyContracts();

        for (uint256 i = 0; i < fixedAddressCoreContracts.length; ++i) {
            for (uint256 j = 0; j < zksyncOSOnlyContracts.length; ++j) {
                assertTrue(
                    fixedAddressCoreContracts[i] != zksyncOSOnlyContracts[j],
                    "ZKsync-OS-only contract leaked into the shared list"
                );
            }
        }
    }

    /// @dev Same accessor the factory-dependency builder uses for ZKsync OS: the deployed EVM bytecode.
    function _deployedBytecode(CoreContract _contract) private view returns (bytes memory) {
        (, string memory contractName) = CoreOnGatewayHelper.resolve(true, _contract);
        return ContractsBytecodesLib.getL2DeployedBytecode(contractName, true);
    }

    function _countBytecode(bytes[] memory _bytecodes, bytes32 _hash) private pure returns (uint256 count) {
        for (uint256 i = 0; i < _bytecodes.length; ++i) {
            if (keccak256(_bytecodes[i]) == _hash) {
                ++count;
            }
        }
    }

    function _containsAddress(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        address _address
    ) private pure returns (bool) {
        for (uint256 i = 0; i < _deployments.length; ++i) {
            if (_deployments[i].newAddress == _address) {
                return true;
            }
        }
        return false;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
