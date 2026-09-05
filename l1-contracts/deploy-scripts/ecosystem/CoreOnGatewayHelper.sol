// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";

import {CoreContract, L2SystemContract} from "./CoreContract.sol";
import {UnknownCoreContract, UnknownL2SystemContract} from "./DeployScriptErrors.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_ROOT_STORAGE,
    L2_MESSAGE_ROOT_ADDR,
    L2_MESSAGE_VERIFICATION,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_NTV_BEACON_DEPLOYER_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @title CoreOnGatewayHelper
/// @notice Resolves CoreContract enum values to ZKsyncOS artifact names
///         and provides bytecode / force-deployment helpers for core L2 contracts.
///         Delegates bytecode reading to ContractsBytecodesLib / BytecodeUtils.
library CoreOnGatewayHelper {
    // ======================== Name resolution ========================

    /// @notice Resolve a CoreContract to its (fileName, contractName).
    function resolve(CoreContract _c) internal view returns (string memory fileName, string memory contractName) {
        contractName = _resolveContractName(_c);
        fileName = string.concat(contractName, ".sol");
    }

    // ======================== Bytecode info ========================

    /// @notice Get bytecode info for force deployments / upgrades:
    ///         proxy-upgrade bytecode info (impl + SystemContractProxy blake2s).
    function getBytecodeInfo(CoreContract _c) internal returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_c);
        return Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
    }

    /// @notice Get a bytecode hash (keccak256) of the deployed EVM bytecode.
    /// @dev Note, that it is NOT suitable for force deployments as these require bytecode info.
    function getDeployedBytecodeHash(CoreContract _c) internal view returns (bytes32) {
        (string memory fileName, string memory contractName) = resolve(_c);
        return BytecodeUtils.getDeployedBytecodeHash(fileName, contractName);
    }

    // ======================== Factory dependencies ========================

    function getFullListOfFactoryDependencies(
        CoreContract[] memory _additionalDependencyContracts
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

    function _getSharedFactoryDependencyContracts() private pure returns (CoreContract[] memory dependencyContracts) {
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
        CoreContract[] memory fixedAddressCoreContracts = SystemContractsProcessing.getFixedAddressCoreContracts();
        dependencyContracts = new CoreContract[](fixedAddressCoreContracts.length + 1);
        uint256 index;
        for (uint256 i = 0; i < fixedAddressCoreContracts.length; i++) {
            dependencyContracts[index++] = fixedAddressCoreContracts[i];
        }
        dependencyContracts[index] = CoreContract.UpgradeableBeaconDeployer;
    }

    function _getFactoryDependencyBytecodes(
        CoreContract[] memory _dependencyContracts
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

    /// @notice Resolve a CoreContract enum to its contract name.
    function _resolveContractName(CoreContract _c) internal pure returns (string memory) {
        if (_c == CoreContract.L2NativeTokenVault) return "L2NativeTokenVault";

        if (_c == CoreContract.L2Bridgehub) return "L2Bridgehub";
        if (_c == CoreContract.L2AssetRouter) return "L2AssetRouter";
        if (_c == CoreContract.L2MessageRoot) return "L2MessageRoot";
        if (_c == CoreContract.UpgradeableBeaconDeployer) return "UpgradeableBeaconDeployer";
        if (_c == CoreContract.BaseTokenHolder) return "BaseTokenHolder";
        if (_c == CoreContract.L2ChainAssetHandler) return "L2ChainAssetHandler";
        if (_c == CoreContract.InteropCenter) return "InteropCenter";
        if (_c == CoreContract.InteropAttributeParser) return "InteropAttributeParser";
        if (_c == CoreContract.L2InteropCommitmentTree) return "L2InteropCommitmentTree";
        if (_c == CoreContract.AtomicFlowManager) return "AtomicFlowManager";
        if (_c == CoreContract.L2InteropHandler) return "L2InteropHandler";
        if (_c == CoreContract.L2AssetTracker) return "L2AssetTracker";
        if (_c == CoreContract.L2WrappedBaseToken) return "L2WrappedBaseToken";
        if (_c == CoreContract.L2MessageVerification) return "L2MessageVerification";
        if (_c == CoreContract.L2InteropRootStorage) return "L2InteropRootStorage";
        if (_c == CoreContract.BeaconProxy) return "BeaconProxy";
        if (_c == CoreContract.L2V32Upgrade) return "L2V32Upgrade";
        if (_c == CoreContract.BridgedStandardERC20) return "BridgedStandardERC20";
        if (_c == CoreContract.DiamondProxy) return "DiamondProxy";
        if (_c == CoreContract.ProxyAdmin) return "ProxyAdmin";
        if (_c == CoreContract.TransparentUpgradeableProxy) return "TransparentUpgradeableProxy";

        revert UnknownCoreContract();
    }

    /// @notice Resolve a CoreContract enum to its canonical L2 address.
    /// @dev Only covers contracts with well-known constant addresses.
    function _resolveAddress(CoreContract _c) internal pure returns (address) {
        if (_c == CoreContract.L2V32Upgrade) {
            return L2_VERSION_SPECIFIC_UPGRADER_ADDR;
        }
        if (_c == CoreContract.L2Bridgehub) return L2_BRIDGEHUB_ADDR;
        if (_c == CoreContract.L2AssetRouter) return L2_ASSET_ROUTER_ADDR;
        if (_c == CoreContract.L2NativeTokenVault) return L2_NATIVE_TOKEN_VAULT_ADDR;
        if (_c == CoreContract.L2MessageRoot) return L2_MESSAGE_ROOT_ADDR;
        if (_c == CoreContract.L2WrappedBaseToken) return L2_WRAPPED_BASE_TOKEN_IMPL_ADDR;
        if (_c == CoreContract.L2MessageVerification) return address(L2_MESSAGE_VERIFICATION);
        if (_c == CoreContract.L2ChainAssetHandler) return L2_CHAIN_ASSET_HANDLER_ADDR;
        if (_c == CoreContract.L2InteropRootStorage) return address(L2_INTEROP_ROOT_STORAGE);
        if (_c == CoreContract.BaseTokenHolder) return L2_BASE_TOKEN_HOLDER_ADDR;
        if (_c == CoreContract.L2AssetTracker) return L2_ASSET_TRACKER_ADDR;
        if (_c == CoreContract.InteropCenter) return L2_INTEROP_CENTER_ADDR;
        if (_c == CoreContract.InteropAttributeParser) return L2_INTEROP_ATTRIBUTE_PARSER_ADDR;
        if (_c == CoreContract.L2InteropHandler) return L2_INTEROP_HANDLER_ADDR;
        if (_c == CoreContract.UpgradeableBeaconDeployer) return L2_NTV_BEACON_DEPLOYER_ADDR;
        if (_c == CoreContract.L2InteropCommitmentTree) return L2_INTEROP_COMMITMENT_TREE_ADDR;
        if (_c == CoreContract.AtomicFlowManager) return L2_ATOMIC_FLOW_MANAGER_ADDR;
        revert UnknownCoreContract();
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
        if (_c == L2SystemContract.L2BaseToken) return "L2BaseToken";
        if (_c == L2SystemContract.L1Messenger) return "L1Messenger";
        if (_c == L2SystemContract.SystemContext) return "SystemContext";
        if (_c == L2SystemContract.ContractDeployer) return "ContractDeployer";
        if (_c == L2SystemContract.L2ComplexUpgrader) {
            return "L2ComplexUpgrader";
        }
        revert UnknownL2SystemContract();
    }

    /// @notice Resolve an L2SystemContract to its canonical L2 address.
    function _resolveL2SystemContractAddress(L2SystemContract _c) internal pure returns (address) {
        if (_c == L2SystemContract.L2BaseToken) return L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
        if (_c == L2SystemContract.L1Messenger) return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR;
        if (_c == L2SystemContract.SystemContext) return L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        if (_c == L2SystemContract.ContractDeployer) return L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        if (_c == L2SystemContract.L2ComplexUpgrader) {
            return L2_COMPLEX_UPGRADER_ADDR;
        }
        revert UnknownL2SystemContract();
    }
}
