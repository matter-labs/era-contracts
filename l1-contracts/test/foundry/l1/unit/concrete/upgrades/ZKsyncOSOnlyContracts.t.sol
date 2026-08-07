// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreContract} from "deploy-scripts/ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "deploy-scripts/ecosystem/CoreOnGatewayHelper.sol";
import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {ContractsBytecodesLib} from "deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_REMOVED_GW_ASSET_TRACKER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice The ZKsync-OS-only contracts are force-deployed from their own list, so their bytecodes have to
/// be merged into the ZKsync OS factory dependencies separately. A force deployment whose preimage is not
/// published makes the L2 upgrade transaction panic on the first access to the missing code, which no
/// fixture that installs bytecode itself (`vm.etch`, `anvil_setCode`) would notice.
contract ZKsyncOSOnlyContractsTest is Test {
    function test_forceDeploymentsCarryTheRightBytecodeForEachAddress() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseZKsyncOSForceDeployments();

        // Each entry must pair the expected address with the bytecode info of *that* contract: an entry that
        // deployed the flow manager's code at the tree's address would satisfy a presence-only check while
        // making `initL2` fail on a real chain.
        _assertDeploysContractAt(deployments, L2_INTEROP_COMMITMENT_TREE_ADDR, CoreContract.L2InteropCommitmentTree);
        _assertDeploysContractAt(deployments, L2_ATOMIC_FLOW_MANAGER_ADDR, CoreContract.AtomicFlowManager);
    }

    /// @dev Asserts the list has exactly one entry for `_address`, that it is a system-proxy upgrade, and that
    ///      its bytecode info is the one `_contract` resolves to.
    function _assertDeploysContractAt(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        address _address,
        CoreContract _contract
    ) private {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, _contract);
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
            .getBaseZKsyncOSForceDeployments();
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

        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, new CoreContract[](0));
        bytes32 emptyContractCodeHash = keccak256(
            BytecodeUtils.readDeployedBytecodeL1(true, "EmptyContract.sol", "EmptyContract")
        );
        assertEq(
            _countBytecode(factoryDeps, emptyContractCodeHash),
            1,
            "EmptyContract preimage not published exactly once"
        );
    }

    function test_zkSyncOSFactoryDependenciesIncludeTheNewBuiltInImplementations() public {
        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, new CoreContract[](0));

        // The implementation preimages of the two new built-ins, which is what this release adds to the
        // list. Their `SystemContractProxy` preimage is shared with every other ZKsync OS force deployment
        // and is published by the same list builder, so it is not re-checked here.
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

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
