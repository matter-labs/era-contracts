// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreContract, L2SystemContract} from "deploy-scripts/ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "deploy-scripts/ecosystem/CoreOnGatewayHelper.sol";
import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {ContractsBytecodesLib} from "deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_REMOVED_GW_ASSET_TRACKER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Additional fixed-address contracts are force-deployed from their own list, so their bytecodes
/// have to be merged into the factory dependencies separately. A force deployment whose preimage is not
/// published makes the L2 upgrade transaction panic on the first access to the missing code, which no
/// fixture that installs bytecode itself (`vm.etch`, `anvil_setCode`) would notice.
contract SystemContractsProcessingTest is Test {
    function test_forceDeploymentsCarryTheRightBytecodeForEachAddress() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseForceDeployments();

        // Each entry must pair the expected address with the bytecode info of *that* contract: an entry that
        // deployed the flow manager's code at the tree's address would satisfy a presence-only check while
        // making `initL2` fail on a real chain.
        _assertDeploysContractAt(deployments, L2_INTEROP_COMMITMENT_TREE_ADDR, CoreContract.L2InteropCommitmentTree);
        _assertDeploysContractAt(deployments, L2_ATOMIC_FLOW_MANAGER_ADDR, CoreContract.AtomicFlowManager);
    }

    /// @notice Existing OS chains must replace the v31 ComplexUpgrader implementation that still
    /// exposes the Era force-deployment entry point. Its implementation preimage must accompany the
    /// force-deployment entry or a real OS node cannot materialize the derived implementation address.
    function test_forceDeploymentsUpgradeComplexUpgraderAndPublishImplementation() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseForceDeployments();
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolveL2SystemContract(
            L2SystemContract.L2ComplexUpgrader
        );
        bytes memory expectedBytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);

        uint256 matches;
        for (uint256 i = 0; i < deployments.length; ++i) {
            if (deployments[i].newAddress != L2_COMPLEX_UPGRADER_ADDR) {
                continue;
            }
            ++matches;
            assertEq(
                uint256(deployments[i].upgradeType),
                uint256(IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade),
                "the ComplexUpgrader must remain behind its system proxy"
            );
            assertEq(
                keccak256(deployments[i].deployedBytecodeInfo),
                keccak256(expectedBytecodeInfo),
                "the ComplexUpgrader entry carries the wrong bytecode"
            );
        }
        assertEq(matches, 1, "expected exactly one ComplexUpgrader deployment");

        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(new CoreContract[](0));
        bytes32 implementationCodeHash = keccak256(ContractsBytecodesLib.getL2DeployedBytecode(contractName));
        assertEq(
            _countBytecode(factoryDeps, implementationCodeHash),
            1,
            "ComplexUpgrader implementation preimage not published exactly once"
        );
    }

    /// @dev Asserts the list has exactly one entry for `_address`, that it is a system-proxy upgrade, and that
    ///      its bytecode info is the one `_contract` resolves to.
    function _assertDeploysContractAt(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        address _address,
        CoreContract _contract
    ) private {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(_contract);
        bytes memory expectedBytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);

        uint256 matches;
        for (uint256 i = 0; i < _deployments.length; ++i) {
            if (_deployments[i].newAddress != _address) {
                continue;
            }
            ++matches;
            assertEq(
                uint256(_deployments[i].upgradeType),
                uint256(IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade),
                "unexpected upgrade type"
            );
            assertEq(
                keccak256(_deployments[i].deployedBytecodeInfo),
                keccak256(expectedBytecodeInfo),
                "entry carries another contract's bytecode"
            );
        }
        assertEq(matches, 1, "expected exactly one deployment for the address");
    }

    /// @notice The removed v31 GWAssetTracker must be neutralized: exactly one system-proxy entry
    /// for its reserved address, installing the EmptyContract implementation, and the EmptyContract
    /// preimage must be published with the factory dependencies.
    function test_forceDeploymentsNeutralizeTheRemovedTracker() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseForceDeployments();
        bytes memory emptyContractInfo = Utils.getZKOSProxyUpgradeBytecodeInfo("EmptyContract.sol", "EmptyContract");

        uint256 matches;
        for (uint256 i = 0; i < deployments.length; ++i) {
            if (deployments[i].newAddress != L2_REMOVED_GW_ASSET_TRACKER_ADDR) {
                continue;
            }
            ++matches;
            assertEq(
                uint256(deployments[i].upgradeType),
                uint256(IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade),
                "neutralization must be a system-proxy implementation swap"
            );
            assertEq(
                keccak256(deployments[i].deployedBytecodeInfo),
                keccak256(emptyContractInfo),
                "the removed tracker's proxy must point at EmptyContract"
            );
        }
        assertEq(matches, 1, "expected exactly one neutralization for the removed tracker");

        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(new CoreContract[](0));
        bytes32 emptyContractCodeHash = keccak256(
            BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract")
        );
        assertEq(
            _countBytecode(factoryDeps, emptyContractCodeHash),
            1,
            "EmptyContract preimage not published exactly once"
        );
    }

    function test_factoryDependenciesIncludeTheNewBuiltInImplementations() public {
        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(new CoreContract[](0));

        // The implementation preimages of the two new built-ins, which is what this release adds to the
        // list. Their `SystemContractProxy` preimage is shared with every other force deployment
        // and is published by the same list builder, so it is not re-checked here.
        CoreContract[] memory additionalCoreContracts = SystemContractsProcessing
            .getAdditionalFixedAddressCoreContracts();
        for (uint256 i = 0; i < additionalCoreContracts.length; ++i) {
            bytes32 expected = keccak256(_deployedBytecode(additionalCoreContracts[i]));
            assertEq(_countBytecode(factoryDeps, expected), 1, "bytecode not published exactly once");
        }
    }

    function test_fixedAddressAndAdditionalContractListsDoNotOverlap() public {
        // Both lists are concatenated into one force-deployment array, so duplicates are invalid.
        CoreContract[] memory fixedAddressCoreContracts = SystemContractsProcessing.getFixedAddressCoreContracts();
        CoreContract[] memory additionalCoreContracts = SystemContractsProcessing
            .getAdditionalFixedAddressCoreContracts();

        for (uint256 i = 0; i < fixedAddressCoreContracts.length; ++i) {
            for (uint256 j = 0; j < additionalCoreContracts.length; ++j) {
                assertTrue(
                    fixedAddressCoreContracts[i] != additionalCoreContracts[j],
                    "contract appears in both force-deployment lists"
                );
            }
        }
    }

    /// @dev Same accessor the factory-dependency builder uses: the deployed EVM bytecode.
    function _deployedBytecode(CoreContract _contract) private view returns (bytes memory) {
        (, string memory contractName) = CoreOnGatewayHelper.resolve(_contract);
        return ContractsBytecodesLib.getL2DeployedBytecode(contractName);
    }

    function _countBytecode(bytes[] memory _bytecodes, bytes32 _hash) private pure returns (uint256 count) {
        for (uint256 i = 0; i < _bytecodes.length; ++i) {
            if (keccak256(_bytecodes[i]) == _hash) {
                ++count;
            }
        }
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
