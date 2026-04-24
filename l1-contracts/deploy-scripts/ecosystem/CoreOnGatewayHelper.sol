// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";

import {
    CoreContract,
    EraVmSystemContract,
    Language,
    ZkSyncOsSystemContract,
    ZKsyncOSUpgradeType
} from "./CoreContract.sol";
import {UnknownCoreContract, UnknownZkSyncOsSystemContract, UnknownEraVmSystemContract} from "./DeployScriptErrors.sol";
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
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_NTV_BEACON_DEPLOYER_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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

    function getCreate2DerivedForceDeploymentAddr(CoreContract _c) internal view returns (address) {
        return Utils.getL2AddressViaCreate2Factory(bytes32(0), getDeployedBytecodeHash(false, _c), hex"");
    }

    function getEraForceDeploymentAddress(CoreContract _c) internal view returns (address) {
        if (_c == CoreContract.L2V29Upgrade || _c == CoreContract.L2V31Upgrade) {
            return L2_VERSION_SPECIFIC_UPGRADER_ADDR;
        }

        return _resolveAddress(_c);
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
            newAddress: getEraForceDeploymentAddress(_c),
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
        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies(_isZKsyncOS);
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

        // The ZkSyncOsSystemContract list (L2BaseTokenZKOS, L1MessengerZKOS, SystemContext,
        // ZKOSContractDeployer) is force-deployed by buildZKsyncOSForceDeployments at upgrade
        // time but lives in a separate enum — without this merge their preimages never land
        // in the sequencer's oracle and the VM panics on the first SLOAD of their code.
        if (_isZKsyncOS) {
            factoryDeps = SystemContractsProcessing.mergeBytesArrays(factoryDeps, _getZKsyncOSExtraBytecodes());
        }

        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }

    // ======================== Private helpers ========================

    function _getSharedFactoryDependencyContracts(
        bool _isZKsyncOS
    ) private pure returns (CoreContract[] memory dependencyContracts) {
        if (_isZKsyncOS) {
            // Reuse the canonical "other built-in" list — the same contracts
            // `buildZKsyncOSForceDeployments` force-deploys on L2 at upgrade
            // time. Every bytecode hash the upgrade tx's force-deploy path
            // queries must appear in the tx's `factory_deps`, otherwise the
            // server has no way to know which `EVMBytecodePublished` events
            // on `BytecodesSupplier` it should load into the preimage store
            // and the VM panics on the first missing preimage.
            //
            // Plus `UpgradeableBeaconDeployer`, which
            // `FixedForceDeploymentsData.beaconDeployerInfo` references but
            // which isn't part of `getOtherBuiltinCoreContracts()`.
            CoreContract[] memory builtins = SystemContractsProcessing.getOtherBuiltinCoreContracts();
            dependencyContracts = new CoreContract[](builtins.length + 1);
            for (uint256 i = 0; i < builtins.length; i++) {
                dependencyContracts[i] = builtins[i];
            }
            dependencyContracts[builtins.length] = CoreContract.UpgradeableBeaconDeployer;
            return dependencyContracts;
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

    /// @notice EVM deployed bytecodes for the ZkSyncOsSystemContract enum (L2BaseTokenZKOS,
    ///         L1MessengerZKOS, SystemContext, ZKOSContractDeployer). Parallel loop to
    ///         `_getFactoryDependencyBytecodes` because the enums aren't interchangeable.
    function _getZKsyncOSExtraBytecodes() private view returns (bytes[] memory out) {
        ZkSyncOsSystemContract[] memory ids = SystemContractsProcessing.getZKsyncOSExtraSystemContracts();
        out = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            string memory contractName = _resolveZkOsSystemContractName(ids[i]);
            out[i] = ContractsBytecodesLib.getL2DeployedBytecode(contractName, true);
        }
    }

    /// @notice Resolve a CoreContract enum to its contract name for the active VM.
    function _resolveContractName(bool _isZKsyncOS, CoreContract _c) internal pure returns (string memory) {
        // Contracts with different names per VM
        if (_c == CoreContract.L2NativeTokenVault) return _isZKsyncOS ? "L2NativeTokenVaultZKOS" : "L2NativeTokenVault";

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
        if (_c == CoreContract.TransparentUpgradeableProxy) return "TransparentUpgradeableProxy";

        revert UnknownCoreContract();
    }

    /// @notice Resolve a CoreContract enum to its ZKsyncOS upgrade type.
    /// @dev Explicit per-contract mapping — no default fallback, so adding a new
    ///      contract forces the developer to decide the upgrade type here.
    function _resolveUpgradeType(CoreContract _c) internal pure returns (ZKsyncOSUpgradeType) {
        if (_c == CoreContract.L2Bridgehub) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2AssetRouter) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2NativeTokenVault) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2MessageRoot) return ZKsyncOSUpgradeType.SystemProxy;
        // Sits at L2_WRAPPED_BASE_TOKEN_IMPL_ADDR directly as the impl (not a proxy);
        // user-space WETH proxies reference this address. Upgrade via bytecode replacement.
        if (_c == CoreContract.L2WrappedBaseToken) return ZKsyncOSUpgradeType.Unsafe;
        if (_c == CoreContract.L2MessageVerification) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2ChainAssetHandler) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2InteropRootStorage) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.BaseTokenHolder) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.L2AssetTracker) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.InteropCenter) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.InteropHandler) return ZKsyncOSUpgradeType.SystemProxy;
        if (_c == CoreContract.GWAssetTracker) return ZKsyncOSUpgradeType.SystemProxy;
        revert UnknownCoreContract();
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
        if (_c == CoreContract.UpgradeableBeaconDeployer) return L2_NTV_BEACON_DEPLOYER_ADDR;
        revert UnknownCoreContract();
    }

    // ======================== ZkSyncOsSystemContract resolvers ========================

    /// @notice Resolve a ZkSyncOsSystemContract to its (fileName, contractName) pair.
    function resolveZkOsSystemContract(
        ZkSyncOsSystemContract _c
    ) internal pure returns (string memory fileName, string memory contractName) {
        contractName = _resolveZkOsSystemContractName(_c);
        fileName = string.concat(contractName, ".sol");
    }

    /// @notice Resolve a ZkSyncOsSystemContract to its ZKsyncOS contract name.
    function _resolveZkOsSystemContractName(ZkSyncOsSystemContract _c) internal pure returns (string memory) {
        if (_c == ZkSyncOsSystemContract.L2BaseToken) return "L2BaseTokenZKOS";
        if (_c == ZkSyncOsSystemContract.L1Messenger) return "L1MessengerZKOS";
        if (_c == ZkSyncOsSystemContract.SystemContext) return "SystemContext";
        if (_c == ZkSyncOsSystemContract.ContractDeployer) return "ZKOSContractDeployer";
        revert UnknownZkSyncOsSystemContract();
    }

    /// @notice Resolve a ZkSyncOsSystemContract to its canonical L2 address.
    function _resolveZkOsSystemContractAddress(ZkSyncOsSystemContract _c) internal pure returns (address) {
        if (_c == ZkSyncOsSystemContract.L2BaseToken) return L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
        if (_c == ZkSyncOsSystemContract.L1Messenger) return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR;
        if (_c == ZkSyncOsSystemContract.SystemContext) return L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        if (_c == ZkSyncOsSystemContract.ContractDeployer) return L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        revert UnknownZkSyncOsSystemContract();
    }

    // ======================== EraVmSystemContract resolvers ========================

    /// @notice Maps an EraVmSystemContract to its deployed address.
    function _resolveAddress(EraVmSystemContract _id) internal pure returns (address) {
        if (_id == EraVmSystemContract.EmptyContract_0x0000) return address(0x0000);
        if (_id == EraVmSystemContract.Ecrecover) return address(0x0001);
        if (_id == EraVmSystemContract.SHA256) return address(0x0002);
        if (_id == EraVmSystemContract.Identity) return address(0x0004);
        if (_id == EraVmSystemContract.EcAdd) return address(0x0006);
        if (_id == EraVmSystemContract.EcMul) return address(0x0007);
        if (_id == EraVmSystemContract.EcPairing) return address(0x0008);
        if (_id == EraVmSystemContract.Modexp) return address(0x0005);
        if (_id == EraVmSystemContract.EmptyContract_0x8001) return address(0x8001);
        if (_id == EraVmSystemContract.AccountCodeStorage) return address(0x8002);
        if (_id == EraVmSystemContract.NonceHolder) return address(0x8003);
        if (_id == EraVmSystemContract.KnownCodesStorage) return address(0x8004);
        if (_id == EraVmSystemContract.ImmutableSimulator) return address(0x8005);
        if (_id == EraVmSystemContract.ContractDeployer) return address(0x8006);
        if (_id == EraVmSystemContract.L1Messenger) return address(0x8008);
        if (_id == EraVmSystemContract.MsgValueSimulator) return address(0x8009);
        if (_id == EraVmSystemContract.L2BaseToken) return address(0x800A);
        if (_id == EraVmSystemContract.SystemContext) return address(0x800B);
        if (_id == EraVmSystemContract.BootloaderUtilities) return address(0x800C);
        if (_id == EraVmSystemContract.EventWriter) return address(0x800D);
        if (_id == EraVmSystemContract.Compressor) return address(0x800E);
        if (_id == EraVmSystemContract.Keccak256) return address(0x8010);
        if (_id == EraVmSystemContract.CodeOracle) return address(0x8012);
        if (_id == EraVmSystemContract.EvmGasManager) return address(0x8013);
        if (_id == EraVmSystemContract.EvmPredeploysManager) return address(0x8014);
        if (_id == EraVmSystemContract.EvmHashesStorage) return address(0x8015);
        if (_id == EraVmSystemContract.P256Verify) return address(0x0100);
        if (_id == EraVmSystemContract.PubdataChunkPublisher) return address(0x8011);
        if (_id == EraVmSystemContract.Create2Factory) return address(0x10000);
        if (_id == EraVmSystemContract.SloadContract) return address(0x10006);
        revert UnknownEraVmSystemContract();
    }

    /// @notice Maps an EraVmSystemContract to its Era code name.
    function _resolveContractName(EraVmSystemContract _id) internal pure returns (string memory) {
        if (_id == EraVmSystemContract.EmptyContract_0x0000) return "EmptyContract";
        if (_id == EraVmSystemContract.Ecrecover) return "Ecrecover";
        if (_id == EraVmSystemContract.SHA256) return "SHA256";
        if (_id == EraVmSystemContract.Identity) return "Identity";
        if (_id == EraVmSystemContract.EcAdd) return "EcAdd";
        if (_id == EraVmSystemContract.EcMul) return "EcMul";
        if (_id == EraVmSystemContract.EcPairing) return "EcPairing";
        if (_id == EraVmSystemContract.Modexp) return "Modexp";
        if (_id == EraVmSystemContract.EmptyContract_0x8001) return "EmptyContract";
        if (_id == EraVmSystemContract.AccountCodeStorage) return "AccountCodeStorage";
        if (_id == EraVmSystemContract.NonceHolder) return "NonceHolder";
        if (_id == EraVmSystemContract.KnownCodesStorage) return "KnownCodesStorage";
        if (_id == EraVmSystemContract.ImmutableSimulator) return "ImmutableSimulator";
        if (_id == EraVmSystemContract.ContractDeployer) return "ContractDeployer";
        if (_id == EraVmSystemContract.L1Messenger) return "L1Messenger";
        if (_id == EraVmSystemContract.MsgValueSimulator) return "MsgValueSimulator";
        if (_id == EraVmSystemContract.L2BaseToken) return "L2BaseToken";
        if (_id == EraVmSystemContract.SystemContext) return "SystemContext";
        if (_id == EraVmSystemContract.BootloaderUtilities) return "BootloaderUtilities";
        if (_id == EraVmSystemContract.EventWriter) return "EventWriter";
        if (_id == EraVmSystemContract.Compressor) return "Compressor";
        if (_id == EraVmSystemContract.Keccak256) return "Keccak256";
        if (_id == EraVmSystemContract.CodeOracle) return "CodeOracle";
        if (_id == EraVmSystemContract.EvmGasManager) return "EvmGasManager";
        if (_id == EraVmSystemContract.EvmPredeploysManager) return "EvmPredeploysManager";
        if (_id == EraVmSystemContract.EvmHashesStorage) return "EvmHashesStorage";
        if (_id == EraVmSystemContract.P256Verify) return "P256Verify";
        if (_id == EraVmSystemContract.PubdataChunkPublisher) return "PubdataChunkPublisher";
        if (_id == EraVmSystemContract.Create2Factory) return "Create2Factory";
        if (_id == EraVmSystemContract.SloadContract) return "SloadContract";
        revert UnknownEraVmSystemContract();
    }

    /// @notice Maps an EraVmSystemContract to its programming language.
    function _resolveLanguage(EraVmSystemContract _id) internal pure returns (Language) {
        if (
            _id == EraVmSystemContract.Ecrecover ||
            _id == EraVmSystemContract.SHA256 ||
            _id == EraVmSystemContract.Identity ||
            _id == EraVmSystemContract.EcAdd ||
            _id == EraVmSystemContract.EcMul ||
            _id == EraVmSystemContract.EcPairing ||
            _id == EraVmSystemContract.Modexp ||
            _id == EraVmSystemContract.EventWriter ||
            _id == EraVmSystemContract.Keccak256 ||
            _id == EraVmSystemContract.CodeOracle ||
            _id == EraVmSystemContract.EvmGasManager ||
            _id == EraVmSystemContract.P256Verify
        ) {
            return Language.Yul;
        }
        return Language.Solidity;
    }

    /// @notice Maps an EraVmSystemContract to whether it is a precompile.
    function _resolveIsPrecompile(EraVmSystemContract _id) internal pure returns (bool) {
        return (_id == EraVmSystemContract.Ecrecover ||
            _id == EraVmSystemContract.SHA256 ||
            _id == EraVmSystemContract.Identity ||
            _id == EraVmSystemContract.EcAdd ||
            _id == EraVmSystemContract.EcMul ||
            _id == EraVmSystemContract.EcPairing ||
            _id == EraVmSystemContract.Modexp ||
            _id == EraVmSystemContract.Keccak256 ||
            _id == EraVmSystemContract.CodeOracle ||
            _id == EraVmSystemContract.P256Verify);
    }
}
