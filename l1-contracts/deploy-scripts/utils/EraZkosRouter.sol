// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2_CREATE2_FACTORY_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {BytecodePublisher} from "./bytecode/BytecodePublisher.s.sol";
import {ContractsBytecodesLib} from "./bytecode/ContractsBytecodesLib.sol";

// Sub-module libraries (internal implementation details)
import {EraZkosVerifierLifecycle} from "./vm/EraZkosVerifierLifecycle.sol";
import {ChainCreationParamsLib} from "../ctm/ChainCreationParamsLib.sol";
import {ChainCreationParamsConfig} from "./Types.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";

/// @notice Canonical identifier for contracts that participate in CTM deployment.
///         The enum value is VM-neutral; the strategy resolves it to the correct
///         Era or ZKsyncOS contract name.
enum EraZkosContract {
    // ---- Force-deployment contracts (used in FixedForceDeploymentsData) ----
    L2Bridgehub,
    L2AssetRouter,
    L2NativeTokenVault,
    L2MessageRoot,
    UpgradeableBeaconDeployer,
    BaseTokenHolder,
    L2ChainAssetHandler,
    InteropCenter,
    InteropHandler,
    L2AssetTracker,
    BeaconProxy,
    L2V29Upgrade,
    L2V31Upgrade,
    L2SharedBridgeLegacy,
    BridgedStandardERC20,
    DiamondProxy,
    ProxyAdmin,
    // ---- CTM / state-transition contracts ----
    ChainTypeManager,
    VerifierFflonk,
    VerifierPlonk,
    DualVerifier,
    TestnetVerifier,
    L2BaseToken,
    GatewayCTMDeployerCTM,
    GatewayCTMDeployerVerifiers
}

/// @notice Result of preparing an L1->L2 deployment (CREATE2 via Era or ZKsyncOS factory).
struct L1L2DeployPrepareResult {
    address expectedAddress;
    bytes data;
    address targetAddress;
}

/// @notice Result of publishing and processing factory dependencies.
struct FactoryDepsResult {
    /// @dev Factory dep hashes for the upgrade transaction.
    ///      Era: L2 bytecode hashes as uint256. ZKsyncOS: empty array.
    uint256[] factoryDepsHashes;
}

/// @title EraZkosRouter
/// @notice Centralizes all Era-vs-ZKsyncOS deployment decisions.
/// @dev Use as a library: pass `_isZKsyncOS` as the first argument to every function.
///      Delegates to sub-module libraries for specific concerns:
///        - EraZkosVerifierLifecycle: verifier creation, initialization, introspection
///        - ChainCreationParamsLib: genesis config loading
library EraZkosRouter {
    string private constant GENESIS_FILENAME_ERA = "era/latest.json";
    string private constant GENESIS_FILENAME_ZKOS = "zksync-os/latest.json";

    // ======================== Contract registry ========================

    /// @notice Resolve a EraZkosContract to its (fileName, contractName) for the active VM.
    // solhint-disable-next-line code-complexity
    function resolve(
        bool _isZKsyncOS,
        EraZkosContract _c
    ) internal view returns (string memory fileName, string memory contractName) {
        contractName = _resolveContractName(_isZKsyncOS, _c);
        fileName = string.concat(contractName, ".sol");
    }

    /// @notice Resolve the main verifier (dual or testnet) for the active VM.
    function resolveMainVerifier(
        bool _isZKsyncOS,
        bool _testnet
    ) internal view returns (string memory fileName, string memory contractName) {
        return resolve(_isZKsyncOS, _testnet ? EraZkosContract.TestnetVerifier : EraZkosContract.DualVerifier);
    }

    // ======================== Bytecode reading ========================

    /// @notice Read L1 contract bytecode from the correct artifact directory.
    ///         ZKsyncOS -> out/ (EVM artifacts), Era -> zkout/ (ZK artifacts).
    function readBytecodeL1(bool _isZKsyncOS, EraZkosContract _c) internal returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_isZKsyncOS, _c);
        return _readBytecodeL1(_isZKsyncOS, fileName, contractName);
    }

    /// @notice Raw variant for callers that already have file/contract names (e.g. facets).
    function readBytecodeL1Raw(
        bool _isZKsyncOS,
        string memory _fileName,
        string memory _contractName
    ) internal returns (bytes memory) {
        return _readBytecodeL1(_isZKsyncOS, _fileName, _contractName);
    }

    /// @notice Convenience overload: derives fileName as contractName + ".sol".
    function readBytecodeL1Raw(bool _isZKsyncOS, string memory _contractName) internal returns (bytes memory) {
        return _readBytecodeL1(_isZKsyncOS, string.concat(_contractName, ".sol"), _contractName);
    }

    // ======================== Bytecode info encoding ========================

    /// @notice Get bytecode info for force deployments / upgrades.
    ///         Era:      abi.encode(L2BytecodeHash).
    ///         ZKsyncOS: proxy-upgrade bytecode info (impl + SystemContractProxy blake2s).
    function getBytecodeInfo(bool _isZKsyncOS, EraZkosContract _c) internal returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_isZKsyncOS, _c);
        if (_isZKsyncOS) {
            return Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
        }
        return abi.encode(L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1(fileName, contractName)));
    }

    /// @notice Get a bytecode hash of the deployed bytecode.
    ///         Era:      L2ContractHelper.hashL2Bytecode (ZK bytecode hash).
    ///         ZKsyncOS: keccak256 of deployed EVM bytecode.
    /// @dev Note, that for zksync os it is NOT suitable for force deployments as these require bytecode info.
    function getDeployedBytecodeHash(bool _isZKsyncOS, EraZkosContract _c) internal view returns (bytes32) {
        (string memory fileName, string memory contractName) = resolve(_isZKsyncOS, _c);
        if (_isZKsyncOS) {
            return keccak256(Utils.readFoundryDeployedBytecodeL1(fileName, contractName));
        }
        return L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1(fileName, contractName));
    }

    // ======================== CREATE2 address computation ========================

    /// @notice Compute a CREATE2 address using the VM-appropriate derivation.
    ///         Era:      ZKsync-specific (hashL2Bytecode-based).
    ///         ZKsyncOS: standard EVM (initCode-based).
    function computeCreate2Address(
        bool _isZKsyncOS,
        address _deployer,
        bytes32 _salt,
        bytes memory _bytecode,
        bytes memory _constructorArgs
    ) internal returns (address) {
        if (_isZKsyncOS) {
            bytes memory initCode = abi.encodePacked(_bytecode, _constructorArgs);
            return Utils.vm.computeCreate2Address(_salt, keccak256(initCode), _deployer);
        }
        return
            L2ContractHelper.computeCreate2Address(
                _deployer,
                _salt,
                L2ContractHelper.hashL2Bytecode(_bytecode),
                keccak256(_constructorArgs)
            );
    }

    // ======================== Factory deps / bytecode publishing ========================

    /// @notice Publish bytecodes and compute factory dependency hashes in one call.
    ///         Era:      publishes bytecodes, computes L2 bytecode hashes, returns populated result.
    ///         ZKsyncOS: publishes bytecodes, returns empty array (no factory deps concept).
    function publishAndProcessFactoryDeps(
        bool _isZKsyncOS,
        BytecodesSupplier _supplier,
        bytes[] memory _allDeps
    ) internal returns (FactoryDepsResult memory result) {
        _publishBytecodes(_isZKsyncOS, _supplier, _allDeps);

        if (_isZKsyncOS) {
            result.factoryDepsHashes = new uint256[](0);
            return result;
        }

        uint256 depsLen = _allDeps.length;
        require(depsLen <= 64, "Too many deps");

        result.factoryDepsHashes = new uint256[](depsLen);
        for (uint256 i = 0; i < depsLen; i++) {
            result.factoryDepsHashes[i] = uint256(L2ContractHelper.hashL2Bytecode(_allDeps[i]));
        }
    }

    function getFullListOfFactoryDependencies(
        bool _isZKsyncOS,
        EraZkosContract[] memory _additionalDependencyContracts
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

    /// @notice Check if a bytecode hash is present in the factory deps result.
    ///         For ZKsyncOS (empty result), always returns true since factory deps are not used.
    function isHashInFactoryDeps(FactoryDepsResult memory _result, bytes32 _hash) internal pure returns (bool) {
        if (_result.factoryDepsHashes.length == 0) {
            return true;
        }
        for (uint256 i = 0; i < _result.factoryDepsHashes.length; i++) {
            if (bytes32(_result.factoryDepsHashes[i]) == _hash) {
                return true;
            }
        }
        return false;
    }

    // ======================== Genesis config ========================

    /// @notice Absolute path to genesis / chain-creation JSON under `configs/genesis/` for the given VM mode.
    function genesisConfigPath(bool _isZKsyncOS) internal returns (string memory) {
        return
            string.concat(
                Utils.vm.projectRoot(),
                "/../configs/genesis/",
                _isZKsyncOS ? GENESIS_FILENAME_ZKOS : GENESIS_FILENAME_ERA
            );
    }

    /// @notice Load chain creation params from the genesis config file at the given path.
    function getChainCreationParams(
        bool _isZKsyncOS,
        string memory _configPath
    ) internal returns (ChainCreationParamsConfig memory) {
        return ChainCreationParamsLib.getChainCreationParams(_configPath, _isZKsyncOS);
    }

    // ======================== Verifier lifecycle (delegated to EraZkosVerifierLifecycle) ========================

    /// @notice ZKsyncOS verifiers take an extra `owner` parameter.
    function verifierCreationArgs(
        bool _isZKsyncOS,
        address _fflonk,
        address _plonk,
        address _owner
    ) internal view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierCreationArgs(_fflonk, _plonk, _owner, _isZKsyncOS);
    }

    /// @notice Return the creation bytecode for the main (dual or testnet) verifier.
    function getVerifierCreationCode(bool _isZKsyncOS, bool _testnetVerifier) internal view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierCreationCode(_testnetVerifier, _isZKsyncOS);
    }

    /// @notice Return the creation bytecode for the fflonk verifier.
    function getVerifierFflonkCreationCode(bool _isZKsyncOS) internal view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierFflonkCreationCode(_isZKsyncOS);
    }

    /// @notice Return the creation bytecode for the plonk verifier.
    function getVerifierPlonkCreationCode(bool _isZKsyncOS) internal view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierPlonkCreationCode(_isZKsyncOS);
    }

    /// @notice Perform any post-deploy steps required for the verifier.
    function initializeVerifier(
        bool _isZKsyncOS,
        address _verifier,
        address _fflonk,
        address _plonk,
        address _owner
    ) internal {
        EraZkosVerifierLifecycle.initializeVerifier(_verifier, _fflonk, _plonk, _owner, _isZKsyncOS);
    }

    /// @notice Transfer ownership of a ZKsyncOS dual verifier. No-op for Era.
    function transferVerifierOwnership(bool _isZKsyncOS, address _verifier, address _newOwner) internal {
        EraZkosVerifierLifecycle.transferVerifierOwnership(_verifier, _newOwner, _isZKsyncOS);
    }

    /// @notice Retrieve sub-verifier addresses from a deployed dual verifier.
    function getSubVerifiers(
        bool _isZKsyncOS,
        address _verifier
    ) internal view returns (address fflonk, address plonk) {
        return EraZkosVerifierLifecycle.getSubVerifiers(_verifier, _isZKsyncOS);
    }

    // ======================== Force deployments ========================

    function getCreate2DerivedForceDeploymentAddr(
        bool _isZKsyncOS,
        EraZkosContract _c
    ) internal view returns (address) {
        // FIXME: add support for additional force deployments on ZKsyncOS in scripts.
        require(!_isZKsyncOS, "Additional force deployments are not supported for ZKsyncOS scripts");
        return Utils.getL2AddressViaCreate2Factory(bytes32(0), getDeployedBytecodeHash(false, _c), hex"");
    }

    /// @notice Build a force deployment entry for scripts that use additional Era force deployments.
    function getForceDeployment(
        bool _isZKsyncOS,
        EraZkosContract _c
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

    // ======================== L2 deployment target ========================

    /// @notice Return the CREATE2 factory address used for L2 deployments.
    function getDeploymentTarget(bool _isZKsyncOS) internal view returns (address) {
        return _isZKsyncOS ? Utils.DETERMINISTIC_CREATE2_ADDRESS : L2_CREATE2_FACTORY_ADDR;
    }

    // ======================== Upgrade tx type ========================

    /// @notice Return the L2 upgrade transaction type for the active VM.
    function upgradeL2TxType(bool _isZKsyncOS) internal view returns (uint256) {
        return _isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    // ======================== L1 -> L2 CREATE2 preparation ========================

    /// @notice Prepare L1->L2 deployment calldata and expected address (Era vs ZKsyncOS CREATE2 rules).
    function prepareL1L2Deployment(
        bool _isZKsyncOS,
        bytes32 _salt,
        bytes memory _bytecode,
        bytes memory _constructorArgs
    ) internal view returns (L1L2DeployPrepareResult memory result) {
        result.targetAddress = getDeploymentTarget(_isZKsyncOS);
        if (_isZKsyncOS) {
            bytes memory initCode = abi.encodePacked(_bytecode, _constructorArgs);
            result.expectedAddress = Utils.getL2AddressViaDeterministicCreate2(_salt, initCode);
            result.data = Utils.getDeterministicCreate2FactoryCalldata(_salt, initCode);
        } else {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(_bytecode);
            result.expectedAddress = Utils.getL2AddressViaCreate2Factory(_salt, bytecodeHash, _constructorArgs);
            (, result.data) = Utils.getDeploymentCalldata(_salt, _bytecode, _constructorArgs);
        }
    }

    // ======================== Gateway CTM (Era) factory dependencies ========================

    /// @notice Bytecodes required for Gateway CTM deployers on Era; empty array on ZKsyncOS.
    // solhint-disable-next-line code-complexity
    function gatewayCTMEraFactoryDependencies(bool _isZKsyncOS) internal returns (bytes[] memory dependencies) {
        if (_isZKsyncOS) {
            return dependencies;
        }

        uint256 totalDependencies = 27;
        dependencies = new bytes[](totalDependencies);
        uint256 idx = 0;

        // Gateway deployer contracts
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "GatewayCTMDeployerDA");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "GatewayCTMDeployerProxyAdmin");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "GatewayCTMDeployerValidatorTimelock");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "GatewayCTMDeployerVerifiers");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "GatewayCTMDeployerCTM");

        // DA + infrastructure
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "RollupDAManager");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "ValidiumL1DAValidator");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "RelayedSLDAValidator");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "ProxyAdmin");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "ValidatorTimelock");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "TransparentUpgradeableProxy");

        // Verifiers
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "EraVerifierFflonk");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "EraVerifierPlonk");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "EraTestnetVerifier");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "EraDualVerifier");

        // CTM + server
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "ServerNotifier");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "EraChainTypeManager");

        // Diamond facets (file name differs from contract name)
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Admin.sol", "AdminFacet");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Mailbox.sol", "MailboxFacet");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Executor.sol", "ExecutorFacet");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Getters.sol", "GettersFacet");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Migrator.sol", "MigratorFacet");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Committer.sol", "CommitterFacet");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "DiamondInit");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "L1GenesisUpgrade");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "Multicall3");
        dependencies[idx++] = readBytecodeL1Raw(_isZKsyncOS, "DiamondProxy");
    }

    // ======================== Internal helpers ========================

    /// @notice Publish bytecodes to BytecodesSupplier using the VM-appropriate method.
    function _publishBytecodes(bool _isZKsyncOS, BytecodesSupplier _supplier, bytes[] memory _deps) private {
        if (_isZKsyncOS) {
            BytecodePublisher.publishEVMBytecodesInBatches(_supplier, _deps);
        } else {
            BytecodePublisher.publishEraBytecodesInBatches(_supplier, _deps);
        }
    }

    function _getBaseFactoryDependencies(bool _isZKsyncOS) private view returns (bytes[] memory basicDependencies) {
        if (_isZKsyncOS) {
            // FIXME: add support for base factory dependencies on ZKsyncOS in scripts.
            return new bytes[](0);
        }
        return SystemContractsProcessing.getBaseListOfDependencies();
    }

    function _getSharedFactoryDependencyContracts(
        bool _isZKsyncOS
    ) private pure returns (EraZkosContract[] memory dependencyContracts) {
        if (_isZKsyncOS) {
            return new EraZkosContract[](0);
        }

        dependencyContracts = new EraZkosContract[](4);
        dependencyContracts[0] = EraZkosContract.L2SharedBridgeLegacy;
        dependencyContracts[1] = EraZkosContract.BridgedStandardERC20;
        dependencyContracts[2] = EraZkosContract.DiamondProxy;
        dependencyContracts[3] = EraZkosContract.ProxyAdmin;
    }

    function _getFactoryDependencyBytecodes(
        bool _isZKsyncOS,
        EraZkosContract[] memory _dependencyContracts
    ) private returns (bytes[] memory dependencyBytecodes) {
        dependencyBytecodes = new bytes[](_dependencyContracts.length);

        for (uint256 i; i < _dependencyContracts.length; i++) {
            if (_isZKsyncOS) {
                (string memory fileName, string memory contractName) = resolve(_isZKsyncOS, _dependencyContracts[i]);
                dependencyBytecodes[i] = Utils.readFoundryDeployedBytecodeL1(fileName, contractName);
            } else {
                (, string memory contractName) = resolve(false, _dependencyContracts[i]);
                dependencyBytecodes[i] = ContractsBytecodesLib.getCreationCodeEra(contractName);
            }
        }
    }

    function _readBytecodeL1(
        bool _isZKsyncOS,
        string memory _fileName,
        string memory _contractName
    ) private returns (bytes memory) {
        return
            _isZKsyncOS
                ? Utils.readFoundryBytecodeL1(_fileName, _contractName)
                : Utils.readZKFoundryBytecodeL1(_fileName, _contractName);
    }

    /// @notice Resolve a EraZkosContract enum to its contract name for the active VM.
    // solhint-disable-next-line code-complexity
    function _resolveContractName(bool _isZKsyncOS, EraZkosContract _c) private view returns (string memory) {
        // Contracts with different names per VM
        if (_c == EraZkosContract.L2NativeTokenVault)
            return _isZKsyncOS ? "L2NativeTokenVaultZKOS" : "L2NativeTokenVault";
        if (_c == EraZkosContract.ChainTypeManager)
            return _isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        if (_c == EraZkosContract.VerifierFflonk) return _isZKsyncOS ? "ZKsyncOSVerifierFflonk" : "EraVerifierFflonk";
        if (_c == EraZkosContract.VerifierPlonk) return _isZKsyncOS ? "ZKsyncOSVerifierPlonk" : "EraVerifierPlonk";
        if (_c == EraZkosContract.DualVerifier) return _isZKsyncOS ? "ZKsyncOSDualVerifier" : "EraDualVerifier";
        if (_c == EraZkosContract.TestnetVerifier)
            return _isZKsyncOS ? "ZKsyncOSTestnetVerifier" : "EraTestnetVerifier";
        if (_c == EraZkosContract.L2BaseToken) return _isZKsyncOS ? "L2BaseTokenZKOS" : "L2BaseTokenEra";
        if (_c == EraZkosContract.GatewayCTMDeployerCTM) {
            return _isZKsyncOS ? "GatewayCTMDeployerCTMZKsyncOS" : "GatewayCTMDeployerCTM";
        }
        if (_c == EraZkosContract.GatewayCTMDeployerVerifiers) {
            return _isZKsyncOS ? "GatewayCTMDeployerVerifiersZKsyncOS" : "GatewayCTMDeployerVerifiers";
        }

        // Contracts with the same name across both VMs
        if (_c == EraZkosContract.L2Bridgehub) return "L2Bridgehub";
        if (_c == EraZkosContract.L2AssetRouter) return "L2AssetRouter";
        if (_c == EraZkosContract.L2MessageRoot) return "L2MessageRoot";
        if (_c == EraZkosContract.UpgradeableBeaconDeployer) return "UpgradeableBeaconDeployer";
        if (_c == EraZkosContract.BaseTokenHolder) return "BaseTokenHolder";
        if (_c == EraZkosContract.L2ChainAssetHandler) return "L2ChainAssetHandler";
        if (_c == EraZkosContract.InteropCenter) return "InteropCenter";
        if (_c == EraZkosContract.InteropHandler) return "InteropHandler";
        if (_c == EraZkosContract.L2AssetTracker) return "L2AssetTracker";
        if (_c == EraZkosContract.BeaconProxy) return "BeaconProxy";
        if (_c == EraZkosContract.L2V29Upgrade) return "L2V29Upgrade";
        if (_c == EraZkosContract.L2V31Upgrade) return "L2V31Upgrade";
        if (_c == EraZkosContract.L2SharedBridgeLegacy) return "L2SharedBridgeLegacy";
        if (_c == EraZkosContract.BridgedStandardERC20) return "BridgedStandardERC20";
        if (_c == EraZkosContract.DiamondProxy) return "DiamondProxy";
        if (_c == EraZkosContract.ProxyAdmin) return "ProxyAdmin";

        revert("EraZkosRouter: unknown EraZkosContract");
    }
}
