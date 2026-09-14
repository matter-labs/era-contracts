// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";

import {L2EcosystemContract, L2SystemContract, ZKsyncOSUpgradeType} from "./CoreContract.sol";
import {L2InventoryLib} from "contracts/upgrades/registry/libraries/L2InventoryLib.sol";
import {UnknownCoreContract, UnknownL2SystemContract} from "./DeployScriptErrors.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_NTV_BEACON_DEPLOYER_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @title CoreOnGatewayHelper
/// @notice Resolves L2EcosystemContract enum values to ZKsyncOS artifact names
///         and provides bytecode / force-deployment helpers for core L2 contracts.
///         Delegates bytecode reading to ContractsBytecodesLib / BytecodeUtils.
library CoreOnGatewayHelper {
    // ======================== Name resolution ========================

    /// @notice Resolve a L2EcosystemContract to its (fileName, contractName).
    function resolve(
        L2EcosystemContract _c
    ) internal view returns (string memory fileName, string memory contractName) {
        contractName = _resolveContractName(_c);
        fileName = string.concat(contractName, ".sol");
    }

    // ======================== Bytecode info ========================

    /// @notice Get bytecode info for force deployments / upgrades:
    ///         proxy-upgrade bytecode info (impl + SystemContractProxy blake2s).
    function getBytecodeInfo(L2EcosystemContract _c) internal returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_c);
        return Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
    }

    /// @notice Get a bytecode hash (keccak256) of the deployed EVM bytecode.
    /// @dev Note, that it is NOT suitable for force deployments as these require bytecode info.
    function getDeployedBytecodeHash(L2EcosystemContract _c) internal view returns (bytes32) {
        (string memory fileName, string memory contractName) = resolve(_c);
        return BytecodeUtils.getDeployedBytecodeHash(fileName, contractName);
    }

    // ======================== Factory dependencies ========================

    function getFullListOfFactoryDependencies(
        L2EcosystemContract[] memory _additionalDependencyContracts
    ) internal returns (bytes[] memory factoryDeps) {
        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies();
        bytes[] memory sharedDependencies = _getFactoryDependencyBytecodes(_getSharedFactoryDependencyContracts());
        bytes[] memory additionalDependencies = _getFactoryDependencyBytecodes(_additionalDependencyContracts);

        factoryDeps = SystemContractsProcessing.mergeBytesArrays(basicDependencies, sharedDependencies);
        factoryDeps = SystemContractsProcessing.mergeBytesArrays(factoryDeps, additionalDependencies);

        // The L2SystemContract list (L2BaseToken, L1Messenger, SystemContext,
        // L2ComplexUpgrader) is force-deployed by the base deployment builder at upgrade
        // time but lives in a separate enum — without this merge their preimages never land
        // in the sequencer's oracle and the VM panics on the first SLOAD of their code.
        factoryDeps = SystemContractsProcessing.mergeBytesArrays(factoryDeps, _getSystemProxyUpgradeBytecodes());

        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }

    // ======================== Private helpers ========================

    function _getSharedFactoryDependencyContracts()
        private
        pure
        returns (L2EcosystemContract[] memory dependencyContracts)
    {
        // Reuse the canonical fixed-address core contract list - the same contract
        // IDs `getBaseForceDeployments` upgrades on L2 at upgrade
        // time. Every bytecode hash the upgrade tx's force-deploy path
        // queries must appear in the tx's `factory_deps`, otherwise the
        // server has no way to know which `EVMBytecodePublished` events
        // on `BytecodesSupplier` it should load into the preimage store
        // and the VM panics on the first missing preimage.
        //
        // Plus `UpgradeableBeaconDeployer`, which
        // `FixedForceDeploymentsData.beaconDeployerInfo` references but
        // which is not one of the fixed-address core contracts.
        L2EcosystemContract[] memory fixedAddressCoreContracts = SystemContractsProcessing
            .getFixedAddressCoreContracts();
        dependencyContracts = new L2EcosystemContract[](fixedAddressCoreContracts.length + 1);
        uint256 index;
        for (uint256 i = 0; i < fixedAddressCoreContracts.length; i++) {
            dependencyContracts[index++] = fixedAddressCoreContracts[i];
        }
        dependencyContracts[index] = L2EcosystemContract.UpgradeableBeaconDeployer;
    }

    function _getFactoryDependencyBytecodes(
        L2EcosystemContract[] memory _dependencyContracts
    ) private returns (bytes[] memory dependencyBytecodes) {
        dependencyBytecodes = new bytes[](_dependencyContracts.length);

        for (uint256 i; i < _dependencyContracts.length; i++) {
            (, string memory contractName) = resolve(_dependencyContracts[i]);
            dependencyBytecodes[i] = ContractsBytecodesLib.getL2DeployedBytecode(contractName);
        }
    }

    /// @notice EVM deployed bytecodes for the L2SystemContract upgrade list (L2BaseToken,
    ///         L1Messenger, SystemContext, L2ComplexUpgrader). Parallel loop to
    ///         `_getFactoryDependencyBytecodes` because the enums aren't interchangeable.
    function _getSystemProxyUpgradeBytecodes() private view returns (bytes[] memory out) {
        L2SystemContract[] memory ids = SystemContractsProcessing.getSystemProxyUpgradeContracts();
        out = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            string memory contractName = _resolveL2SystemContractName(ids[i]);
            out[i] = ContractsBytecodesLib.getL2DeployedBytecode(contractName);
        }
    }

    /// @notice Resolve a L2EcosystemContract enum to its contract name.
    function _resolveContractName(L2EcosystemContract _c) internal pure returns (string memory) {
        if (_c == L2EcosystemContract.L2NativeTokenVault) {
            return "L2NativeTokenVault";
        }

        if (_c == L2EcosystemContract.L2Bridgehub) return "L2Bridgehub";
        if (_c == L2EcosystemContract.L2AssetRouter) return "L2AssetRouter";
        if (_c == L2EcosystemContract.L2MessageRoot) return "L2MessageRoot";
        if (_c == L2EcosystemContract.UpgradeableBeaconDeployer) return "UpgradeableBeaconDeployer";
        if (_c == L2EcosystemContract.BaseTokenHolder) return "BaseTokenHolder";
        if (_c == L2EcosystemContract.L2ChainAssetHandler) return "L2ChainAssetHandler";
        if (_c == L2EcosystemContract.InteropCenter) return "InteropCenter";
        if (_c == L2EcosystemContract.InteropAttributeParser) return "InteropAttributeParser";
        if (_c == L2EcosystemContract.L2InteropCommitmentTree) return "L2InteropCommitmentTree";
        if (_c == L2EcosystemContract.AtomicFlowManager) return "AtomicFlowManager";
        if (_c == L2EcosystemContract.L2InteropHandler) return "L2InteropHandler";
        if (_c == L2EcosystemContract.L2AssetTracker) return "L2AssetTracker";
        if (_c == L2EcosystemContract.L2WrappedBaseToken) return "L2WrappedBaseToken";
        if (_c == L2EcosystemContract.L2MessageVerification) return "L2MessageVerification";
        if (_c == L2EcosystemContract.L2InteropRootStorage) return "L2InteropRootStorage";
        if (_c == L2EcosystemContract.BeaconProxy) return "BeaconProxy";
        if (_c == L2EcosystemContract.L2V34Upgrade) return "L2V34Upgrade";
        if (_c == L2EcosystemContract.BridgedStandardERC20) return "BridgedStandardERC20";
        if (_c == L2EcosystemContract.DiamondProxy) return "DiamondProxy";
        if (_c == L2EcosystemContract.ProxyAdmin) return "ProxyAdmin";
        if (_c == L2EcosystemContract.TransparentUpgradeableProxy) return "TransparentUpgradeableProxy";

        revert UnknownCoreContract();
    }

    /// @notice Resolve a L2EcosystemContract enum to its ZKsyncOS upgrade type.
    /// @dev Explicit per-contract mapping — no default fallback, so adding a new
    ///      contract forces the developer to decide the upgrade type here.
    function _resolveUpgradeType(L2EcosystemContract _c) internal pure returns (ZKsyncOSUpgradeType) {
        if (_c == L2EcosystemContract.L2Bridgehub) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2AssetRouter) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2NativeTokenVault) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2MessageRoot) return ZKsyncOSUpgradeType.SystemProxy;
        // Sits at L2_WRAPPED_BASE_TOKEN_IMPL_ADDR directly as the impl (not a proxy);
        // user-space WETH proxies reference this address. Upgrade via bytecode replacement.
        if (_c == L2EcosystemContract.L2WrappedBaseToken) return ZKsyncOSUpgradeType.Unsafe;
        if (_c == L2EcosystemContract.L2MessageVerification) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2ChainAssetHandler) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2InteropRootStorage) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.BaseTokenHolder) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2AssetTracker) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.InteropCenter) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.InteropAttributeParser) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2InteropHandler) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == L2EcosystemContract.L2InteropCommitmentTree) {
            return ZKsyncOSUpgradeType.SystemProxy;
        }
        if (_c == L2EcosystemContract.AtomicFlowManager) {
            return ZKsyncOSUpgradeType.SystemProxy;
        }
        revert UnknownCoreContract();
    }

    /// @notice Resolve a L2EcosystemContract enum to its canonical L2 address.
    /// @dev Thin delegate to the on-chain inventory ({L2InventoryLib}), so deploy tooling and the
    ///      transition derivation can never place a member at different addresses.
    function _resolveAddress(L2EcosystemContract _c) internal pure returns (address) {
        return L2InventoryLib.fixedAddress(_c);
    }

    // ======================== L2SystemContract resolvers ========================

    /// @notice Resolve an L2SystemContract to its (fileName, contractName) pair.
    function resolveL2SystemContract(
        L2SystemContract _c
    ) internal pure returns (string memory fileName, string memory contractName) {
        contractName = _resolveL2SystemContractName(_c);
        fileName = string.concat(contractName, ".sol");
    }

    /// @notice Resolve an L2SystemContract to its canonical contract name.
    function _resolveL2SystemContractName(L2SystemContract _c) internal pure returns (string memory) {
        if (_c == L2SystemContract.L2BaseToken) {
            return "L2BaseToken";
        }
        if (_c == L2SystemContract.L1Messenger) {
            return "L1Messenger";
        }
        if (_c == L2SystemContract.SystemContext) {
            return "SystemContext";
        }
        if (_c == L2SystemContract.L2ComplexUpgrader) {
            return "L2ComplexUpgrader";
        }
        revert UnknownL2SystemContract();
    }

    /// @notice Resolve an L2SystemContract to its canonical L2 address.
    function _resolveL2SystemContractAddress(L2SystemContract _c) internal pure returns (address) {
        if (_c == L2SystemContract.L2BaseToken) {
            return L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
        }
        if (_c == L2SystemContract.L1Messenger) {
            return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR;
        }
        if (_c == L2SystemContract.SystemContext) {
            return L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        }
        if (_c == L2SystemContract.L2ComplexUpgrader) {
            return L2_COMPLEX_UPGRADER_ADDR;
        }
        revert UnknownL2SystemContract();
    }
}
