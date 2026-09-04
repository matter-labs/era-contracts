// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";
import {console2 as console} from "forge-std/Script.sol";

import {ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainCreationParams} from "contracts/state-transition/ILegacyChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {GenesisManifestLib} from "contracts/upgrades/registry/libraries/GenesisManifestLib.sol";

import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {L2DACommitmentScheme, ROLLUP_L2_DA_COMMITMENT_SCHEME} from "contracts/common/Config.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";
import {L2EcosystemContract, ZkSyncOsSystemContract} from "../ecosystem/CoreContract.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {MultisigCommitter} from "contracts/state-transition/validators/MultisigCommitter.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";

import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {DeployUtils} from "../utils/deploy/DeployUtils.sol";
import {CTMContract} from "./DeployCTML1OrGateway.sol";
import {ChainCreationParamsLib} from "./ChainCreationParamsLib.sol";

import {
    StateTransitionDeployedAddresses,
    DataAvailabilityDeployedAddresses,
    ChainCreationParamsConfig,
    BridgehubAddresses,
    CoreDeployedAddresses
} from "../utils/Types.sol";
import {CTMContract, CTMCoreDeploymentConfig, DeployCTML1OrGateway} from "./DeployCTML1OrGateway.sol";

import {CTMDeployedAddresses} from "../utils/Types.sol";
import {GenesisConfig, ReleaseGenesisData, ReleaseManifest} from "../../contracts/upgrades/registry/RegistryTypes.sol";

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address deployerAddress;
    uint256 gatewayChainId;
    address ownerAddress;
    bytes32 zkTokenAssetId;
    bool testnetVerifier;
    ContractsConfig contracts;
}

// solhint-disable-next-line gas-struct-packing
struct ContractsConfig {
    address multicall3Addr;
    uint256 validatorTimelockExecutionDelay;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    bytes diamondCutData;
    uint256 maxNumberOfChains;
    // questionable
    address availL1DAValidator;
    ChainCreationParamsConfig chainCreationParams;
}

// solhint-disable-next-line gas-struct-packing
struct GeneratedData {
    bytes forceDeploymentsData;
}

abstract contract DeployCTMUtils is DeployUtils {
    using stdToml for string;

    Config public config;
    // Note: This variable is initialized by concrete implementations before use
    GeneratedData internal generatedData; //slither-disable-line uninitialized-state
    CTMDeployedAddresses internal ctmAddresses;
    // Note: Addresses discovered from already deployed core contracts (Bridgehub, AssetRouter, etc.)
    // This variable is initialized by concrete implementations before use
    CoreDeployedAddresses internal coreAddresses; //slither-disable-line uninitialized-state

    /// @dev Cache for batched blake2s hashing (keccak256(bytecode) => blake2s(bytecode)).
    mapping(bytes32 => bytes32) private _blakeCache;
    /// @dev Complete proxy-upgrade descriptors keyed by artifact identity.
    mapping(bytes32 => bytes) private _bytecodeInfoCache;
    /// @dev Per-run scratch file for the batch blake2s FFI call.
    string internal _blakeBatchTmpFile;

    //slither-disable-next-line reentrancy-benign
    function deployStateTransitionDiamondFacets() internal {
        ctmAddresses.stateTransition.facets.executorFacet = deploySimpleContract("ExecutorFacet");
        ctmAddresses.stateTransition.facets.adminFacet = deploySimpleContract("AdminFacet");
        ctmAddresses.stateTransition.facets.mailboxFacet = deploySimpleContract("MailboxFacet");
        ctmAddresses.stateTransition.facets.gettersFacet = deploySimpleContract("GettersFacet");
        ctmAddresses.stateTransition.facets.migratorFacet = deploySimpleContract("MigratorFacet");
        ctmAddresses.stateTransition.facets.committerFacet = deploySimpleContract("CommitterFacet");
        ctmAddresses.stateTransition.facets.diamondInit = deploySimpleContract("DiamondInit");
        ctmAddresses.stateTransition.currentRelease = deployCurrentRelease();
    }

    /// @dev Virtual so bytecode-light test harnesses can substitute the table: the real builder
    ///      reads every L2 contract's bytecode from artifacts.
    function getL2BytecodeInfoTable() internal virtual returns (bytes[] memory) {
        return SystemContractsProcessing.buildL2BytecodeInfoTable(_getProxyUpgradeBytecodeInfo);
    }

    /// @dev Precompute hashes and complete descriptors for the genesis and release inventories.
    /// Artifact JSON is decoded once per implementation and the shared proxy, then all blake2s
    /// hashes are computed in one FFI process to keep Forge below its script-memory cap.
    function _precomputeBlakeHashes() internal {
        L2EcosystemContract[] memory coreContracts = SystemContractsProcessing.getFixedAddressCoreContracts();
        L2EcosystemContract[] memory zkosOnlyContracts = SystemContractsProcessing.getZKsyncOSOnlyContracts();
        ZkSyncOsSystemContract[] memory systemContracts = SystemContractsProcessing.getZKsyncOSExtraSystemContracts();

        // In addition to the release table, the legacy genesis descriptor needs the beacon
        // deployer, and removed trackers need EmptyContract. SystemContractProxy is shared by all
        // proxy-upgrade descriptors.
        bytes[] memory bytecodes = new bytes[](
            coreContracts.length + zkosOnlyContracts.length + systemContracts.length + 3
        );
        // Every bytecode except the final shared proxy has a proxy-upgrade descriptor.
        bytes32[] memory descriptorKeys = new bytes32[](bytecodes.length - 1);
        uint256 bytecodeIndex;

        for (uint256 i = 0; i < coreContracts.length; i++) {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(coreContracts[i]);
            descriptorKeys[bytecodeIndex] = _bytecodeInfoKey(fileName, contractName);
            bytecodes[bytecodeIndex++] = BytecodeUtils.readDeployedBytecodeL1(fileName, contractName);
        }
        for (uint256 i = 0; i < zkosOnlyContracts.length; i++) {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(zkosOnlyContracts[i]);
            descriptorKeys[bytecodeIndex] = _bytecodeInfoKey(fileName, contractName);
            bytecodes[bytecodeIndex++] = BytecodeUtils.readDeployedBytecodeL1(fileName, contractName);
        }

        {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(
                L2EcosystemContract.UpgradeableBeaconDeployer
            );
            descriptorKeys[bytecodeIndex] = _bytecodeInfoKey(fileName, contractName);
            bytecodes[bytecodeIndex++] = BytecodeUtils.readDeployedBytecodeL1(fileName, contractName);
        }

        for (uint256 i = 0; i < systemContracts.length; i++) {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolveZkOsSystemContract(
                systemContracts[i]
            );
            descriptorKeys[bytecodeIndex] = _bytecodeInfoKey(fileName, contractName);
            bytecodes[bytecodeIndex++] = BytecodeUtils.readDeployedBytecodeL1(fileName, contractName);
        }

        descriptorKeys[bytecodeIndex] = _bytecodeInfoKey("EmptyContract.sol", "EmptyContract");
        bytecodes[bytecodeIndex++] = BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract");
        bytecodes[bytecodeIndex++] = BytecodeUtils.readDeployedBytecodeL1(
            "SystemContractProxy.sol",
            "SystemContractProxy"
        );
        require(bytecodeIndex == bytecodes.length, "bytecode precompute inventory length mismatch");

        string memory tmpFile = bytes(_blakeBatchTmpFile).length != 0
            ? _blakeBatchTmpFile
            : string.concat(vm.projectRoot(), "/script-out/tmp-blake-batch.txt");
        vm.writeFile(tmpFile, "");

        for (uint256 i = 0; i < bytecodes.length; i++) {
            vm.writeLine(tmpFile, vm.toString(bytecodes[i]));
        }

        string[] memory input = new string[](4);
        input[0] = "node";
        input[1] = "./scripts/blake2s256.js";
        input[2] = "--batch";
        input[3] = tmpFile;
        bytes memory result = vm.ffi(input);

        require(result.length == bytecodes.length * 32, "Unexpected batch blake2s result length");
        for (uint256 i = 0; i < bytecodes.length; i++) {
            bytes32 hash;
            assembly {
                hash := mload(add(result, add(32, mul(i, 32))))
            }
            _blakeCache[keccak256(bytecodes[i])] = hash;
        }

        bytes memory proxyBytecodeInfo = _cachedZKOSBytecodeInfo(bytecodes[bytecodes.length - 1]);
        for (uint256 i = 0; i < descriptorKeys.length; i++) {
            _bytecodeInfoCache[descriptorKeys[i]] = abi.encode(
                _cachedZKOSBytecodeInfo(bytecodes[i]),
                proxyBytecodeInfo
            );
        }

        vm.removeFile(tmpFile);
    }

    function _bytecodeInfoKey(string memory _fileName, string memory _contractName) private pure returns (bytes32) {
        return keccak256(abi.encode(_fileName, _contractName));
    }

    function _cachedZKOSBytecodeInfo(bytes memory _bytecode) private view returns (bytes memory) {
        bytes32 key = keccak256(_bytecode);
        bytes32 blakeHash = _blakeCache[key];
        require(blakeHash != bytes32(0), "Blake hash not cached");
        return ZKSyncOSBytecodeInfo.encodeZKSyncOSBytecodeInfo(blakeHash, uint32(_bytecode.length), key);
    }

    function _getProxyUpgradeBytecodeInfo(
        string memory _fileName,
        string memory _contractName
    ) internal view returns (bytes memory) {
        bytes memory bytecodeInfo = _bytecodeInfoCache[_bytecodeInfoKey(_fileName, _contractName)];
        require(bytecodeInfo.length != 0, "Bytecode info not cached");
        return bytecodeInfo;
    }

    /// @notice Deploys the storage-backed genesis registry and pins the freshly deployed facet
    /// set plus the base system contract hashes into it. The chain-creation params point at it
    /// (the CTM's `currentRelease`), and `DiamondInit` reads everything chain-independent
    /// from there — the committed genesis cut carries no facets and no init payload.
    /// @dev The manifest is a constructor argument, so the release is fully initialized the moment
    /// it exists — there is no deployed-but-uninitialized window to front-run.
    function deployCurrentRelease() internal returns (address) {
        require(generatedData.forceDeploymentsData.length != 0, "force deployments data is empty");
        ReleaseManifest memory manifest = GenesisManifestLib.buildGenesisManifest(
            GenesisConfig({
                facets: ctmAddresses.stateTransition.facets,
                verifier: ctmAddresses.stateTransition.verifiers.verifier,
                genesisUpgrade: ctmAddresses.stateTransition.genesisUpgrade,
                genesis: ReleaseGenesisData({
                    // ZKsync OS has no bootloader, default-account or EVM-emulator bytecode: the
                    // release pins zeros, the same values a fresh chain geneses with.
                    bootloaderHash: bytes32(0),
                    defaultAccountHash: bytes32(0),
                    evmEmulatorHash: bytes32(0),
                    fixedForceDeploymentsData: generatedData.forceDeploymentsData,
                    genesisBatchHash: config.contracts.chainCreationParams.genesisRoot,
                    genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
                    genesisIndexRepeatedStorageChanges: uint64(
                        config.contracts.chainCreationParams.genesisRollupLeafIndex
                    )
                }),
                l2BytecodeInfos: getL2BytecodeInfoTable()
            })
        );

        // Via the CREATE2 factory, like every other pipeline deployment — upgrade prepares reach
        // the real chain through the Safe bundle, which replays factory transactions only.
        address release = deployViaCreate2AndNotify(type(CTMRelease).creationCode, abi.encode(manifest), "CTMRelease");

        // Deploy + initialize ran in one transaction inside the factory, so the release is already
        // initialized here with no front-runnable window; this is now a pure sanity assertion.
        require(CTMRelease(release).manifestHash() == keccak256(abi.encode(manifest)), "release manifest mismatch");

        console.log("Bootstrap CTMRelease deployed at:", release);
        return release;
    }

    function initializeConfig(string memory configPath, address bridgehub) internal virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = getBroadcasterAddress();

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

        if (toml.keyExists("$.zk_token_asset_id")) {
            config.zkTokenAssetId = toml.readBytes32("$.zk_token_asset_id");
        }
        require(config.zkTokenAssetId != bytes32(0), "zk_token_asset_id must be non-zero in config");

        config.contracts.governanceSecurityCouncilAddress = toml.readAddress(
            "$.contracts.governance_security_council_address"
        );
        config.contracts.governanceMinDelay = toml.readUint("$.contracts.governance_min_delay");

        config.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath());

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }
    }

    function getChainCreationParamsConfig(
        string memory _config
    ) internal virtual returns (ChainCreationParamsConfig memory chainCreationParams) {
        return ChainCreationParamsLib.getChainCreationParams(_config);
    }

    function getChainCreationDiamondCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (Diamond.DiamondCutData memory diamondCut) {
        // The committed genesis cut is only the DiamondInit address: no `facetCuts` and no init
        // payload. `DiamondInit` reads the facet set and the base system contract hashes from
        // the CTM's pinned `currentRelease`.
        diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: stateTransition.facets.diamondInit,
            initCalldata: ""
        });
    }

    function getChainCreationParams(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainCreationParams memory) {
        require(generatedData.forceDeploymentsData.length != 0, "force deployments data is empty");
        require(stateTransition.currentRelease != address(0), "current release is not deployed");
        Diamond.DiamondCutData memory diamondCut = getChainCreationDiamondCutData(stateTransition);
        config.contracts.diamondCutData = abi.encode(diamondCut);
        return
            ChainCreationParams({
                genesisUpgrade: stateTransition.genesisUpgrade,
                genesisBatchHash: config.contracts.chainCreationParams.genesisRoot,
                genesisIndexRepeatedStorageChanges: uint64(config.contracts.chainCreationParams.genesisRollupLeafIndex),
                genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
                diamondCut: diamondCut,
                forceDeploymentsData: generatedData.forceDeploymentsData
            });
    }

    function getChainTypeManagerInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainTypeManagerInitializeData memory) {
        require(stateTransition.currentRelease != address(0), "current release is not deployed");
        // Populate `config.contracts.diamondCutData` (a legacy output field) for serialization.
        getChainCreationParams(stateTransition);
        return
            ChainTypeManagerInitializeData({
                owner: getBroadcasterAddress(),
                validatorTimelock: stateTransition.proxies.validatorTimelock,
                releaseCodehash: stateTransition.currentRelease.codehash,
                currentRelease: stateTransition.currentRelease,
                protocolVersion: config.contracts.chainCreationParams.latestProtocolVersion,
                serverNotifier: stateTransition.proxies.serverNotifier
            });
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function getRollupL2DACommitmentScheme() internal returns (L2DACommitmentScheme) {
        return ROLLUP_L2_DA_COMMITMENT_SCHEME;
    }

    function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "EIP7702Checker")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupDAManager")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return abi.encode(ctmAddresses.daAddresses.daContracts.rollupSLDAValidator);
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return abi.encode(ctmAddresses.daAddresses.availBridge);
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ZKsyncOSVerifierPlonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgradeZKsyncOS")) {
            return abi.encode();
        } else if (compareStrings(contractName, "BootstrapUpgradeZKsyncOS")) {
            // The bootstrap engine pins the genesis release it installs as an immutable.
            require(ctmAddresses.stateTransition.currentRelease != address(0), "current release is not deployed");
            return abi.encode(ctmAddresses.stateTransition.currentRelease);
        } else if (compareStrings(contractName, "Governance")) {
            return
                abi.encode(
                    config.ownerAddress,
                    config.contracts.governanceSecurityCouncilAddress,
                    config.contracts.governanceMinDelay
                );
        } else if (compareStrings(contractName, "ChainAdminOwnable")) {
            return abi.encode(config.ownerAddress, address(0));
        } else if (compareStrings(contractName, "AccessControlRestriction")) {
            return abi.encode(uint256(0), config.ownerAddress);
        } else if (compareStrings(contractName, "ChainAdmin")) {
            address[] memory restrictions = new address[](1);
            restrictions[0] = ctmAddresses.admin.accessControlRestrictionAddress;
            return abi.encode(restrictions);
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "PermissionlessValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return abi.encode();
        } else if (compareStrings(contractName, "GettersFacet")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "MultisigCommitter")) {
            // Same constructor as ValidatorTimelock (it derives from it): the bridgehub immutable.
            return abi.encode(coreAddresses.bridgehub.proxies.bridgehub);
        } else {
            return
                DeployCTML1OrGateway.getCreationCalldata(
                    getCTMCoreDeploymentConfig(config),
                    DeployCTML1OrGateway.getCTMContractFromName(contractName)
                );
        }
    }

    function getCTMCoreDeploymentConfig(Config memory _config) internal view returns (CTMCoreDeploymentConfig memory) {
        return
            CTMCoreDeploymentConfig({
                testnetVerifier: _config.testnetVerifier,
                l1ChainId: _config.l1ChainId,
                bridgehubProxy: coreAddresses.bridgehub.proxies.bridgehub,
                interopCenterProxy: L2_INTEROP_CENTER_ADDR,
                rollupDAManager: ctmAddresses.daAddresses.daContracts.rollupDAManager,
                chainAssetHandler: coreAddresses.bridgehub.proxies.chainAssetHandler,
                l1BytecodesSupplier: ctmAddresses.stateTransition.proxies.bytecodesSupplier,
                eip7702Checker: ctmAddresses.admin.eip7702Checker,
                verifierFflonk: ctmAddresses.stateTransition.verifiers.verifierFflonk,
                verifierPlonk: ctmAddresses.stateTransition.verifiers.verifierPlonk,
                permissionlessValidator: ctmAddresses.stateTransition.proxies.permissionlessValidator
            });
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManagerBase.initialize,
                    getChainTypeManagerInitializeData(ctmAddresses.stateTransition)
                );
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encodeCall(ServerNotifier.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return
                abi.encodeCall(
                    ValidatorTimelock.initialize,
                    (config.deployerAddress, uint32(config.contracts.validatorTimelockExecutionDelay))
                );
        } else if (compareStrings(contractName, "MultisigCommitter")) {
            // `initializeV2`, not the inherited `initialize`: a fresh proxy has to land at
            // `_initialized = 2` with the EIP-712 domain set, matching one that got there via
            // `reinitializeV2` during the v31 upgrade.
            return
                abi.encodeCall(
                    MultisigCommitter.initializeV2,
                    (config.deployerAddress, uint32(config.contracts.validatorTimelockExecutionDelay))
                );
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encodeCall(BytecodesSupplier.initialize, ());
        } else if (compareStrings(contractName, "PermissionlessValidator")) {
            return abi.encodeCall(PermissionlessValidator.initialize, ());
        } else {
            revert(string.concat("Contract ", contractName, " initialize calldata not set"));
        }
    }

    function transparentProxyAdmin() internal view override returns (address) {
        return ctmAddresses.admin.transparentProxyAdmin;
    }

    function getBroadcasterAddress() internal view virtual returns (address) {
        return tx.origin;
    }

    function test() internal virtual {}
}
