// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2_CREATE2_FACTORY_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {BytecodePublisher} from "./bytecode/BytecodePublisher.s.sol";

// Sub-module libraries (internal implementation details)
import {EraZkosVerifierLifecycle} from "./vm/EraZkosVerifierLifecycle.sol";
import {EraZkosForceDeployments} from "./vm/EraZkosForceDeployments.sol";
import {EraZkosGenesisConfig} from "./vm/EraZkosGenesisConfig.sol";
import {ChainCreationParamsConfig} from "./Types.sol";

/// @notice Genesis JSON filenames and absolute paths under `configs/genesis/` (shared by chain-creation params).
library EraZkosPaths {
    string internal constant FILENAME_ERA = "era/latest.json";
    string internal constant FILENAME_ZKOS = "zksync-os/latest.json";

    /// @notice Absolute path to genesis / chain-creation JSON for the given VM mode.
    function genesisConfigPath(bool _isZKsyncOS) internal returns (string memory) {
        return
            string.concat(Utils.vm.projectRoot(), "/../configs/genesis/", _isZKsyncOS ? FILENAME_ZKOS : FILENAME_ERA);
    }
}

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
/// @dev Instantiate once in the script with `new EraZkosRouter(isZKsyncOS)`.
///      All methods read the VM mode from the immutable set at construction.
///      Delegates to sub-module libraries for specific concerns:
///        - EraZkosVerifierLifecycle: verifier creation, initialization, introspection
///        - EraZkosForceDeployments: force deployment bytecode hashing
///        - EraZkosGenesisConfig: genesis config loading
contract EraZkosRouter {
    bool public immutable IS_ZKSYNC_OS;

    constructor(bool _isZKsyncOS) {
        IS_ZKSYNC_OS = _isZKsyncOS;
    }

    /// @notice Same as `IS_ZKSYNC_OS`; preferred at call sites that mirror `config.isZKsyncOS` naming.
    function isZKsyncOS() public view returns (bool) {
        return IS_ZKSYNC_OS;
    }

    // ======================== Contract registry ========================

    /// @notice Resolve a EraZkosContract to its (fileName, contractName) for the active VM.
    // solhint-disable-next-line code-complexity
    function resolve(EraZkosContract _c) public view returns (string memory fileName, string memory contractName) {
        contractName = _resolveContractName(_c);
        fileName = string.concat(contractName, ".sol");
    }

    /// @notice Resolve the main verifier (dual or testnet) for the active VM.
    function resolveMainVerifier(
        bool _testnet
    ) public view returns (string memory fileName, string memory contractName) {
        return resolve(_testnet ? EraZkosContract.TestnetVerifier : EraZkosContract.DualVerifier);
    }

    // ======================== Bytecode reading ========================

    /// @notice Read L1 contract bytecode from the correct artifact directory.
    ///         ZKsyncOS -> out/ (EVM artifacts), Era -> zkout/ (ZK artifacts).
    function readBytecodeL1(EraZkosContract _c) public returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_c);
        return _readBytecodeL1(fileName, contractName);
    }

    /// @notice Raw variant for callers that already have file/contract names (e.g. facets).
    function readBytecodeL1Raw(string memory _fileName, string memory _contractName) public returns (bytes memory) {
        return _readBytecodeL1(_fileName, _contractName);
    }

    /// @notice Convenience overload: derives fileName as contractName + ".sol".
    function readBytecodeL1Raw(string memory _contractName) public returns (bytes memory) {
        return _readBytecodeL1(string.concat(_contractName, ".sol"), _contractName);
    }

    // ======================== Bytecode info encoding ========================

    /// @notice Get bytecode info for force deployments / upgrades.
    ///         Era:      abi.encode(L2BytecodeHash).
    ///         ZKsyncOS: proxy-upgrade bytecode info (impl + SystemContractProxy blake2s).
    function getBytecodeInfo(EraZkosContract _c) public returns (bytes memory) {
        (string memory fileName, string memory contractName) = resolve(_c);
        if (IS_ZKSYNC_OS) {
            return Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
        }
        return abi.encode(L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1(fileName, contractName)));
    }

    /// @notice Get a bytecode hash suitable for force deployments / upgrades.
    ///         Era:      L2ContractHelper.hashL2Bytecode (ZK bytecode hash).
    ///         ZKsyncOS: keccak256 of deployed EVM bytecode.
    function getBytecodeHash(EraZkosContract _c) public view returns (bytes32) {
        (string memory fileName, string memory contractName) = resolve(_c);
        if (IS_ZKSYNC_OS) {
            return keccak256(Utils.readFoundryDeployedBytecodeL1(fileName, contractName));
        }
        return L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1(fileName, contractName));
    }

    // ======================== CREATE2 address computation ========================

    /// @notice Compute a CREATE2 address using the VM-appropriate derivation.
    ///         Era:      ZKsync-specific (hashL2Bytecode-based).
    ///         ZKsyncOS: standard EVM (initCode-based).
    function computeCreate2Address(
        address _deployer,
        bytes32 _salt,
        bytes memory _bytecode,
        bytes memory _constructorArgs
    ) public returns (address) {
        if (IS_ZKSYNC_OS) {
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
        BytecodesSupplier _supplier,
        bytes[] memory _allDeps
    ) public returns (FactoryDepsResult memory result) {
        _publishBytecodes(_supplier, _allDeps);

        if (IS_ZKSYNC_OS) {
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

    /// @notice Check if a bytecode hash is present in the factory deps result.
    ///         For ZKsyncOS (empty result), always returns true since factory deps are not used.
    function isHashInFactoryDeps(FactoryDepsResult memory _result, bytes32 _hash) public pure returns (bool) {
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

    function genesisConfigPath() public returns (string memory) {
        return EraZkosPaths.genesisConfigPath(IS_ZKSYNC_OS);
    }

    /// @notice Load chain creation params from the genesis config file at the given path.
    function getChainCreationParams(string memory _configPath) public returns (ChainCreationParamsConfig memory) {
        return EraZkosGenesisConfig.getChainCreationParams(_configPath, IS_ZKSYNC_OS);
    }

    // ======================== Verifier lifecycle (delegated to EraZkosVerifierLifecycle) ========================

    /// @notice ZKsyncOS verifiers take an extra `owner` parameter.
    function verifierCreationArgs(address _fflonk, address _plonk, address _owner) public view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierCreationArgs(_fflonk, _plonk, _owner, IS_ZKSYNC_OS);
    }

    /// @notice Return the creation bytecode for the main (dual or testnet) verifier.
    function getVerifierCreationCode(bool _testnetVerifier) public view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierCreationCode(_testnetVerifier, IS_ZKSYNC_OS);
    }

    /// @notice Return the creation bytecode for the fflonk verifier.
    function getVerifierFflonkCreationCode() public view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierFflonkCreationCode(IS_ZKSYNC_OS);
    }

    /// @notice Return the creation bytecode for the plonk verifier.
    function getVerifierPlonkCreationCode() public view returns (bytes memory) {
        return EraZkosVerifierLifecycle.getVerifierPlonkCreationCode(IS_ZKSYNC_OS);
    }

    /// @notice Perform any post-deploy steps required for the verifier.
    /// @dev WARNING: This routes through EraZkosRouter, changing msg.sender.
    ///      For broadcast contexts where the caller must be the verifier owner,
    ///      use EraZkosVerifierLifecycle.initializeVerifier() directly as a library call.
    function initializeVerifier(address _verifier, address _fflonk, address _plonk, address _owner) public {
        EraZkosVerifierLifecycle.initializeVerifier(_verifier, _fflonk, _plonk, _owner, IS_ZKSYNC_OS);
    }

    /// @notice Transfer ownership of a ZKsyncOS dual verifier. No-op for Era.
    /// @dev WARNING: Same msg.sender caveat as initializeVerifier. Use the library directly
    ///      when calling from a broadcast context.
    function transferVerifierOwnership(address _verifier, address _newOwner) public {
        EraZkosVerifierLifecycle.transferVerifierOwnership(_verifier, _newOwner, IS_ZKSYNC_OS);
    }

    /// @notice Retrieve sub-verifier addresses from a deployed dual verifier.
    function getSubVerifiers(address _verifier) public view returns (address fflonk, address plonk) {
        return EraZkosVerifierLifecycle.getSubVerifiers(_verifier, IS_ZKSYNC_OS);
    }

    // ======================== Force deployments (delegated to EraZkosForceDeployments) ========================

    /// @notice Compute the bytecode hash for a force deployment entry.
    ///         Era:      L2ContractHelper.hashL2Bytecode of ZK creation code.
    ///         ZKsyncOS: keccak256 of EVM deployed bytecode.
    function getForceDeploymentBytecodeHash(string memory _contractName) public view returns (bytes32) {
        return EraZkosForceDeployments.getForceDeploymentBytecodeHash(_contractName, IS_ZKSYNC_OS);
    }

    // ======================== L2 deployment target ========================

    /// @notice Return the CREATE2 factory address used for L2 deployments.
    function getDeploymentTarget() public view returns (address) {
        return IS_ZKSYNC_OS ? Utils.DETERMINISTIC_CREATE2_ADDRESS : L2_CREATE2_FACTORY_ADDR;
    }

    // ======================== Upgrade tx type ========================

    /// @notice Return the L2 upgrade transaction type for the active VM.
    function upgradeL2TxType() public view returns (uint256) {
        return IS_ZKSYNC_OS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    // ======================== L1 -> L2 CREATE2 preparation ========================

    /// @notice Prepare L1->L2 deployment calldata and expected address (Era vs ZKsyncOS CREATE2 rules).
    function prepareL1L2Deployment(
        bytes32 _salt,
        bytes memory _bytecode,
        bytes memory _constructorArgs
    ) public view returns (L1L2DeployPrepareResult memory result) {
        result.targetAddress = getDeploymentTarget();
        if (IS_ZKSYNC_OS) {
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
    function gatewayCTMEraFactoryDependencies() public returns (bytes[] memory dependencies) {
        if (IS_ZKSYNC_OS) {
            return dependencies;
        }

        uint256 totalDependencies = 27;
        dependencies = new bytes[](totalDependencies);
        uint256 idx = 0;

        // Gateway deployer contracts
        dependencies[idx++] = readBytecodeL1Raw("GatewayCTMDeployerDA");
        dependencies[idx++] = readBytecodeL1Raw("GatewayCTMDeployerProxyAdmin");
        dependencies[idx++] = readBytecodeL1Raw("GatewayCTMDeployerValidatorTimelock");
        dependencies[idx++] = readBytecodeL1Raw("GatewayCTMDeployerVerifiers");
        dependencies[idx++] = readBytecodeL1Raw("GatewayCTMDeployerCTM");

        // DA + infrastructure
        dependencies[idx++] = readBytecodeL1Raw("RollupDAManager");
        dependencies[idx++] = readBytecodeL1Raw("ValidiumL1DAValidator");
        dependencies[idx++] = readBytecodeL1Raw("RelayedSLDAValidator");
        dependencies[idx++] = readBytecodeL1Raw("ProxyAdmin");
        dependencies[idx++] = readBytecodeL1Raw("ValidatorTimelock");
        dependencies[idx++] = readBytecodeL1Raw("TransparentUpgradeableProxy");

        // Verifiers
        dependencies[idx++] = readBytecodeL1Raw("EraVerifierFflonk");
        dependencies[idx++] = readBytecodeL1Raw("EraVerifierPlonk");
        dependencies[idx++] = readBytecodeL1Raw("EraTestnetVerifier");
        dependencies[idx++] = readBytecodeL1Raw("EraDualVerifier");

        // CTM + server
        dependencies[idx++] = readBytecodeL1Raw("ServerNotifier");
        dependencies[idx++] = readBytecodeL1Raw("EraChainTypeManager");

        // Diamond facets (file name differs from contract name)
        dependencies[idx++] = readBytecodeL1Raw("Admin.sol", "AdminFacet");
        dependencies[idx++] = readBytecodeL1Raw("Mailbox.sol", "MailboxFacet");
        dependencies[idx++] = readBytecodeL1Raw("Executor.sol", "ExecutorFacet");
        dependencies[idx++] = readBytecodeL1Raw("Getters.sol", "GettersFacet");
        dependencies[idx++] = readBytecodeL1Raw("Migrator.sol", "MigratorFacet");
        dependencies[idx++] = readBytecodeL1Raw("Committer.sol", "CommitterFacet");
        dependencies[idx++] = readBytecodeL1Raw("DiamondInit");
        dependencies[idx++] = readBytecodeL1Raw("L1GenesisUpgrade");
        dependencies[idx++] = readBytecodeL1Raw("Multicall3");
        dependencies[idx++] = readBytecodeL1Raw("DiamondProxy");
    }

    // ======================== Internal helpers ========================

    /// @notice Publish bytecodes to BytecodesSupplier using the VM-appropriate method.
    function _publishBytecodes(BytecodesSupplier _supplier, bytes[] memory _deps) private {
        if (IS_ZKSYNC_OS) {
            BytecodePublisher.publishEVMBytecodesInBatches(_supplier, _deps);
        } else {
            BytecodePublisher.publishEraBytecodesInBatches(_supplier, _deps);
        }
    }

    function _readBytecodeL1(string memory _fileName, string memory _contractName) private returns (bytes memory) {
        return
            IS_ZKSYNC_OS
                ? Utils.readFoundryBytecodeL1(_fileName, _contractName)
                : Utils.readZKFoundryBytecodeL1(_fileName, _contractName);
    }

    /// @notice Resolve a EraZkosContract enum to its contract name for the active VM.
    // solhint-disable-next-line code-complexity
    function _resolveContractName(EraZkosContract _c) private view returns (string memory) {
        // Contracts with different names per VM
        if (_c == EraZkosContract.L2NativeTokenVault)
            return IS_ZKSYNC_OS ? "L2NativeTokenVaultZKOS" : "L2NativeTokenVault";
        if (_c == EraZkosContract.ChainTypeManager)
            return IS_ZKSYNC_OS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        if (_c == EraZkosContract.VerifierFflonk) return IS_ZKSYNC_OS ? "ZKsyncOSVerifierFflonk" : "EraVerifierFflonk";
        if (_c == EraZkosContract.VerifierPlonk) return IS_ZKSYNC_OS ? "ZKsyncOSVerifierPlonk" : "EraVerifierPlonk";
        if (_c == EraZkosContract.DualVerifier) return IS_ZKSYNC_OS ? "ZKsyncOSDualVerifier" : "EraDualVerifier";
        if (_c == EraZkosContract.TestnetVerifier)
            return IS_ZKSYNC_OS ? "ZKsyncOSTestnetVerifier" : "EraTestnetVerifier";
        if (_c == EraZkosContract.L2BaseToken) return IS_ZKSYNC_OS ? "L2BaseTokenZKOS" : "L2BaseTokenEra";
        if (_c == EraZkosContract.GatewayCTMDeployerCTM) {
            return IS_ZKSYNC_OS ? "GatewayCTMDeployerCTMZKsyncOS" : "GatewayCTMDeployerCTM";
        }
        if (_c == EraZkosContract.GatewayCTMDeployerVerifiers) {
            return IS_ZKSYNC_OS ? "GatewayCTMDeployerVerifiersZKsyncOS" : "GatewayCTMDeployerVerifiers";
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

        revert("EraZkosRouter: unknown EraZkosContract");
    }
}
