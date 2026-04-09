// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";

import {CoreContract, ZKsyncOSUpgradeType} from "./CoreContract.sol";
import {
    GW_ASSET_TRACKER_ADDR,
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

/// @title CoreOnGatewayHelper
/// @notice Resolves CoreContract enum values to VM-specific artifact names
///         and provides bytecode / force-deployment helpers for core L2 contracts.
///         Delegates bytecode reading to ContractsBytecodesLib / BytecodeUtils.
library CoreOnGatewayHelper {
    // ======================== Name resolution ========================

    /// @notice Resolve a CoreContract to its (fileName, contractName) for the active VM.
    function resolve(
        bool _isZKsyncOS,
        CoreContract _c
    ) internal view returns (string memory fileName, string memory contractName) {
        contractName = _resolveContractName(_isZKsyncOS, _c);
        fileName = string.concat(contractName, ".sol");
    }

    // ======================== Bytecode info ========================

    /// @notice Get bytecode info for force deployments / upgrades.
    ///         Era:      abi.encode(L2BytecodeHash).
    ///         ZKsyncOS: proxy-upgrade bytecode info (impl + SystemContractProxy blake2s).
    function getBytecodeInfo(bool _isZKsyncOS, CoreContract _c) internal returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_isZKsyncOS, _c);
        if (_isZKsyncOS) {
            return Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
        }
        return abi.encode(BytecodeUtils.hashBytecode(false, ContractsBytecodesLib.getL2Bytecode(contractName, false)));
    }

    /// @notice Get a bytecode hash of the deployed bytecode.
    ///         Era:      L2ContractHelper.hashL2Bytecode (ZK bytecode hash).
    ///         ZKsyncOS: keccak256 of deployed EVM bytecode.
    /// @dev Note, that for ZKsyncOS it is NOT suitable for force deployments as these require bytecode info.
    function getDeployedBytecodeHash(bool _isZKsyncOS, CoreContract _c) internal view returns (bytes32) {
        (string memory fileName, string memory contractName) = resolve(_isZKsyncOS, _c);
        return BytecodeUtils.getDeployedBytecodeHash(_isZKsyncOS, fileName, contractName);
    }

    // ======================== Force deployments ========================

    function getCreate2DerivedForceDeploymentAddr(bool _isZKsyncOS, CoreContract _c) internal view returns (address) {
        // FIXME: add support for additional force deployments on ZKsyncOS in scripts.
        require(!_isZKsyncOS, "Additional force deployments are not supported for ZKsyncOS scripts");
        return Utils.getL2AddressViaCreate2Factory(bytes32(0), getDeployedBytecodeHash(false, _c), hex"");
    }

    /// @notice Build a force deployment entry for scripts that use additional Era force deployments.
    function getForceDeployment(
        bool _isZKsyncOS,
        CoreContract _c
    ) internal view returns (IL2ContractDeployer.ForceDeployment memory forceDeployment) {
        // FIXME: add support for additional force deployments on ZKsyncOS in scripts.
        require(!_isZKsyncOS, "Additional force deployments are not supported for ZKsyncOS scripts");
        forceDeployment = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: getDeployedBytecodeHash(false, _c),
            newAddress: getCreate2DerivedForceDeploymentAddr(_isZKsyncOS, _c),
            callConstructor: false,
            value: 0,
            input: ""
        });
    }

    // ======================== Factory dependencies ========================

    function getFullListOfFactoryDependencies(
        bool _isZKsyncOS,
        CoreContract[] memory _additionalDependencyContracts
    ) internal returns (bytes[] memory factoryDeps) {
        bytes[] memory basicDependencies = _getBaseFactoryDependencies(_isZKsyncOS);
        bytes[] memory sharedDependencies = _getFactoryDependencyBytecodes(
            _isZKsyncOS,
            _getSharedFactoryDependencyContracts(_isZKsyncOS)
        );
        bytes[] memory additionalDependencies = _getFactoryDependencyBytecodes(
            _isZKsyncOS,
            _additionalDependencyContracts
        );

        factoryDeps = SystemContractsProcessing.mergeBytesArrays(basicDependencies, sharedDependencies);
        factoryDeps = SystemContractsProcessing.mergeBytesArrays(factoryDeps, additionalDependencies);
        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }

    // ======================== Private helpers ========================

    function _getBaseFactoryDependencies(bool _isZKsyncOS) private view returns (bytes[] memory basicDependencies) {
        if (_isZKsyncOS) {
            // FIXME: add support for base factory dependencies on ZKsyncOS in scripts.
            return new bytes[](0);
        }
        return SystemContractsProcessing.getBaseListOfDependencies();
    }

    function _getSharedFactoryDependencyContracts(
        bool _isZKsyncOS
    ) private pure returns (CoreContract[] memory dependencyContracts) {
        if (_isZKsyncOS) {
            return new CoreContract[](0);
        }

        dependencyContracts = new CoreContract[](4);
        dependencyContracts[0] = CoreContract.L2SharedBridgeLegacy;
        dependencyContracts[1] = CoreContract.BridgedStandardERC20;
        dependencyContracts[2] = CoreContract.DiamondProxy;
        dependencyContracts[3] = CoreContract.ProxyAdmin;
    }

    function _getFactoryDependencyBytecodes(
        bool _isZKsyncOS,
        CoreContract[] memory _dependencyContracts
    ) private returns (bytes[] memory dependencyBytecodes) {
        dependencyBytecodes = new bytes[](_dependencyContracts.length);

        for (uint256 i; i < _dependencyContracts.length; i++) {
            (, string memory contractName) = resolve(_isZKsyncOS, _dependencyContracts[i]);
            if (_isZKsyncOS) {
                dependencyBytecodes[i] = ContractsBytecodesLib.getL2DeployedBytecode(contractName, true);
            } else {
                dependencyBytecodes[i] = ContractsBytecodesLib.getCreationCodeEra(contractName);
            }
        }
    }

    /// @notice Resolve a CoreContract enum to its contract name for the active VM.
    function _resolveContractName(bool _isZKsyncOS, CoreContract _c) internal pure returns (string memory) {
        // Contracts with different names per VM
        if (_c == CoreContract.L2NativeTokenVault) return _isZKsyncOS ? "L2NativeTokenVaultZKOS" : "L2NativeTokenVault";
        if (_c == CoreContract.L2BaseToken) return _isZKsyncOS ? "L2BaseTokenZKOS" : "L2BaseTokenEra";

        // Contracts with the same name across both VMs
        if (_c == CoreContract.L2Bridgehub) return "L2Bridgehub";
        if (_c == CoreContract.L2AssetRouter) return "L2AssetRouter";
        if (_c == CoreContract.L2MessageRoot) return "L2MessageRoot";
        if (_c == CoreContract.UpgradeableBeaconDeployer) return "UpgradeableBeaconDeployer";
        if (_c == CoreContract.BaseTokenHolder) return "BaseTokenHolder";
        if (_c == CoreContract.L2ChainAssetHandler) return "L2ChainAssetHandler";
        if (_c == CoreContract.InteropCenter) return "InteropCenter";
        if (_c == CoreContract.InteropHandler) return "InteropHandler";
        if (_c == CoreContract.L2AssetTracker) return "L2AssetTracker";
        if (_c == CoreContract.L2WrappedBaseToken) return "L2WrappedBaseToken";
        if (_c == CoreContract.L2MessageVerification) return "L2MessageVerification";
        if (_c == CoreContract.L2InteropRootStorage) return "L2InteropRootStorage";
        if (_c == CoreContract.GWAssetTracker) return "GWAssetTracker";
        if (_c == CoreContract.BeaconProxy) return "BeaconProxy";
        if (_c == CoreContract.L2V29Upgrade) return "L2V29Upgrade";
        if (_c == CoreContract.L2V31Upgrade) return "L2V31Upgrade";
        if (_c == CoreContract.L2SharedBridgeLegacy) return "L2SharedBridgeLegacy";
        if (_c == CoreContract.BridgedStandardERC20) return "BridgedStandardERC20";
        if (_c == CoreContract.DiamondProxy) return "DiamondProxy";
        if (_c == CoreContract.ProxyAdmin) return "ProxyAdmin";

        revert("CoreOnGatewayHelper: unknown CoreContract");
    }

    /// @notice Resolve a CoreContract enum to its ZKsyncOS upgrade type.
    /// @dev Explicit per-contract mapping — no default fallback, so adding a new
    ///      contract forces the developer to decide the upgrade type here.
    function _resolveUpgradeType(CoreContract _c) internal pure returns (ZKsyncOSUpgradeType) {
        if (_c == CoreContract.L2Bridgehub) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2AssetRouter) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2NativeTokenVault) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2MessageRoot) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2WrappedBaseToken) return ZKsyncOSUpgradeType.Unsafe;
        if (_c == CoreContract.L2MessageVerification) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2ChainAssetHandler) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2InteropRootStorage) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.BaseTokenHolder) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2AssetTracker) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.InteropCenter) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.InteropHandler) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.GWAssetTracker) return ZKsyncOSUpgradeType.Unsafe;
        revert("CoreOnGatewayHelper: no upgrade type for CoreContract");
    }

    /// @notice Resolve a CoreContract enum to its canonical L2 address.
    /// @dev Only covers contracts with well-known constant addresses.
    function _resolveAddress(CoreContract _c) internal pure returns (address) {
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
        if (_c == CoreContract.InteropHandler) return L2_INTEROP_HANDLER_ADDR;
        if (_c == CoreContract.GWAssetTracker) return GW_ASSET_TRACKER_ADDR;
        revert("CoreOnGatewayHelper: no address for CoreContract");
    }
}
