// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "../utils/Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IRollupDAManager} from "../interfaces/IRollupDAManager.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {CTMDeployedAddresses, Config, DeployCTMUtils} from "./DeployCTMUtils.s.sol";
import {CoreContract} from "../ecosystem/CoreContract.sol";
import {CTMContract, DeployCTML1OrGateway} from "./DeployCTML1OrGateway.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

import {IDeployCTM} from "contracts/script-interfaces/IDeployCTM.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

contract DeployCTMScript is Script, DeployCTMUtils, IDeployCTM {
    using stdToml for string;

    /// @dev Cache for batched blake2s hashing (keccak256(bytecode) => blake2s(bytecode)).
    /// ZKsyncOS bytecode info requires blake2s hashes, computed via FFI (`node blake2s256.js`).
    /// Without caching, each call to `Utils.getZKOSProxyUpgradeBytecodeInfo` spawns 2 FFI processes
    /// (one for the impl, one for SystemContractProxy). With ~10 contracts in `_buildForceDeploymentsData`,
    /// that's ~20 sequential FFI calls. The cache batches all bytecodes into a single FFI call in
    /// `_precomputeBlakeHashes()`, reducing deployment time significantly.
    mapping(bytes32 => bytes32) private _blakeCache;

    function run() public virtual {
        // Had to leave the function due to scripts that inherit this one, as well as for tests
        return ();
    }

    function runWithBridgehub(address bridgehub, bool reuseGovAndAdmin) public {
        console.log("Deploying CTM related contracts");
        runInner(
            "/script-config/config-deploy-ctm.toml",
            "/script-out/output-deploy-ctm.toml",
            bridgehub,
            reuseGovAndAdmin,
            false
        );
    }

    function runForTest(address bridgehub, bool skipL1Deployments) public {
        _runConfiguredTest(bridgehub, skipL1Deployments, true);
    }

    /// @notice Like runForTest but skips saveDiamondSelectors().
    function runForAnvilTest(address bridgehub, bool skipL1Deployments) public {
        _runConfiguredTest(bridgehub, skipL1Deployments, false);
    }

    function _runConfiguredTest(address bridgehub, bool skipL1Deployments, bool shouldSaveSelectors) internal {
        if (shouldSaveSelectors) {
            saveDiamondSelectors();
        }
        runInner(vm.envString("CTM_CONFIG"), vm.envString("CTM_OUTPUT"), bridgehub, false, skipL1Deployments);
    }

    function getAddresses() public view virtual returns (CTMDeployedAddresses memory) {
        return ctmAddresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    /// @notice Returns the address to use as the deployer/owner for contracts.
    function getDeployerAddress() public view returns (address) {
        return tx.origin;
    }

    function runInner(
        string memory inputPath,
        string memory outputPath,
        address bridgehub,
        bool reuseGovAndAdmin,
        bool skipL1Deployments
    ) public {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);
        // Scratch file for the batch blake2s FFI call lives next to the
        // output file, so concurrent runs (distinct output paths) don't
        // clobber each other's batches.
        _blakeBatchTmpFile = string.concat(outputPath, ".blake-batch.txt");

        initializeConfig(inputPath, bridgehub);

        console.log("Initializing core contracts from BH");
        IL1Bridgehub bridgehubProxy = IL1Bridgehub(bridgehub);
        // Populate discovered addresses via inspector
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehub);
        address assetRouterAddr = address(bridgehubProxy.assetRouter());
        config.eraChainId = AddressIntrospector.getEraChainId(assetRouterAddr);

        if (reuseGovAndAdmin) {
            ctmAddresses.admin.governance = coreAddresses.shared.governance;
            ctmAddresses.chainAdmin = coreAddresses.shared.bridgehubAdmin;
            ctmAddresses.admin.transparentProxyAdmin = coreAddresses.shared.transparentProxyAdmin;
        } else {
            (ctmAddresses.admin.governance) = deploySimpleContract("Governance", false);
            (ctmAddresses.chainAdmin) = deploySimpleContract("ChainAdminOwnable", false);
            ctmAddresses.admin.transparentProxyAdmin = deployWithCreate2AndOwner(
                "ProxyAdmin",
                ctmAddresses.admin.governance,
                false
            );
        }

        deployEIP7702Checker();
        deployDAValidators();
        deployIfNeededMulticall3();

        (
            ctmAddresses.stateTransition.implementations.bytecodesSupplier,
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        ) = deployTuppWithContract("BytecodesSupplier", false);

        deployVerifiers();

        // The CTM stores this contract and runs it for upgrades that need no custom upgrade logic — e.g.
        // the verifier-only ones — so it has to match the VM of the ecosystem being deployed.
        (, string memory defaultUpgradeName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.DefaultUpgrade
        );
        (ctmAddresses.stateTransition.defaultUpgrade) = deploySimpleContract(defaultUpgradeName, false);
        (ctmAddresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        ctmAddresses.admin.accessControlRestrictionAddress = address(0);

        (, ctmAddresses.stateTransition.proxies.validatorTimelock) = deployTuppWithContract("ValidatorTimelock", false);

        (
            ctmAddresses.stateTransition.implementations.permissionlessValidator,
            ctmAddresses.stateTransition.proxies.permissionlessValidator
        ) = deployTuppWithContract("PermissionlessValidator", false);

        (
            ctmAddresses.stateTransition.implementations.serverNotifier,
            ctmAddresses.stateTransition.proxies.serverNotifier
        ) = deployServerNotifier();

        initializeGeneratedData();

        deployStateTransitionDiamondFacets();
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        (
            ctmAddresses.stateTransition.implementations.chainTypeManager,
            ctmAddresses.stateTransition.proxies.chainTypeManager
        ) = deployTuppWithContract(ctmContractName, false);

        setChainTypeManagerInServerNotifier();

        setDefaultUpgradeInChainTypeManager();

        updateOwners();

        saveOutput(outputPath);
    }

    function initializeGeneratedData() internal {
        generatedData.forceDeploymentsData = prepareForceDeploymentsData();
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on public networks
        if (MULTICALL3_ADDRESS.code.length == 0) {
            address contractAddress = deployViaCreate2(type(Multicall3).creationCode, "");
            console.log("Multicall3 deployed at:", contractAddress);
            config.contracts.multicall3Addr = contractAddress;
        } else {
            config.contracts.multicall3Addr = MULTICALL3_ADDRESS;
        }
    }

    function deployVerifiers() internal {
        (, string memory plonkName) = DeployCTML1OrGateway.resolve(config.isZKsyncOS, CTMContract.VerifierPlonk);

        if (!config.isZKsyncOS) {
            (, string memory fflonkName) = DeployCTML1OrGateway.resolve(false, CTMContract.VerifierFflonk);
            ctmAddresses.stateTransition.verifiers.verifierFflonk = deploySimpleContract(fflonkName, false);
        }
        ctmAddresses.stateTransition.verifiers.verifierPlonk = deploySimpleContract(plonkName, false);

        if (config.multiProof.enabled) {
            deployMultiProofVerifiers();
        } else {
            (, string memory verifierName) = DeployCTML1OrGateway.resolveMainVerifier(
                config.isZKsyncOS,
                config.testnetVerifier
            );
            ctmAddresses.stateTransition.verifiers.verifier = deploySimpleContract(verifierName, false);
        }
    }

    /// @notice Deploy the multi-proof verifier lane, which requires BOTH an
    ///         Airbender proof and a ZiSK proof for each state transition.
    ///         The Airbender side is the ZKsync OS verifier, which holds the
    ///         PLONK sub-verifier that the deployment and upgrade tooling
    ///         introspects.
    function deployMultiProofVerifiers() internal {
        // The Airbender proof is a ZKsync OS proof, so the lane needs the
        // ZKsync OS verifiers.
        require(config.isZKsyncOS, "multi_proof_verifier requires is_zk_sync_os");
        // ZiskVerifier wraps a pre-deployed standalone snarkJS Plonk verifier
        // (see verifiers/README.md for its generation and deployment) passed
        // in by address.
        require(
            config.multiProof.ziskPlonkVerifierAddr != address(0),
            "set zisk_plonk_verifier_addr to the deployed snarkJS Plonk verifier"
        );
        // Deploying it is a manual step outside this script, so the address it
        // leaves behind is checked here rather than at the first settlement.
        require(
            config.multiProof.ziskPlonkVerifierAddr.code.length > 0,
            "zisk_plonk_verifier_addr holds no code: deploy the snarkJS Plonk verifier first"
        );
        // Single-VK lane: every proof, single batch or many, verifies through
        // the range verifier, which reconstructs the ZiSK public values from
        // its own pinned VKs. It defaults to the ZiskVerifier deployed below;
        // an operator may override it with a separately deployed aggregator
        // verifier through zisk_range_verifier_addr, which must already hold
        // code as well.
        if (config.multiProof.ziskRangeVerifierAddr != address(0)) {
            require(
                config.multiProof.ziskRangeVerifierAddr.code.length > 0,
                "zisk_range_verifier_addr holds no code: deploy the range verifier first"
            );
        }
        (, string memory airbenderVerifierName) = DeployCTML1OrGateway.resolveMainVerifier(
            config.isZKsyncOS,
            config.testnetVerifier
        );
        multiProofAddresses.airbenderVerifier = deploySimpleContract(airbenderVerifierName, false);
        multiProofAddresses.ziskVerifier = deploySimpleContract("ZiskVerifier", false);
        if (config.testnetVerifier) {
            multiProofAddresses.ziskTestnetVerifier = deploySimpleContract("ZiskTestnetVerifier", false);
        }
        multiProofAddresses.multiProofVerifier = deploySimpleContract("MultiProofVerifier", false);

        if (config.testnetVerifier) {
            // Testnet: wrap MultiProofVerifier with MultiProofTestnetVerifier for mock proof support.
            ctmAddresses.stateTransition.verifiers.verifier = deploySimpleContract("MultiProofTestnetVerifier", false);
        } else {
            // Prod: use MultiProofVerifier directly.
            ctmAddresses.stateTransition.verifiers.verifier = multiProofAddresses.multiProofVerifier;
        }
    }

    function setChainTypeManagerInServerNotifier() internal {
        ServerNotifier serverNotifier = ServerNotifier(ctmAddresses.stateTransition.proxies.serverNotifier);
        vm.broadcast(getDeployerAddress());
        serverNotifier.setChainTypeManager(IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager));
        console.log("ChainTypeManager set in ServerNotifier");
    }

    function setDefaultUpgradeInChainTypeManager() internal {
        IChainTypeManager ctm = IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager);
        vm.broadcast(getDeployerAddress());
        ctm.setDefaultUpgrade(ctmAddresses.stateTransition.defaultUpgrade);
        console.log("DefaultUpgrade set in ChainTypeManager");
    }

    function deployEIP7702Checker() internal {
        ctmAddresses.admin.eip7702Checker = deploySimpleContract("EIP7702Checker", false);
    }

    function deployDAValidators() internal {
        ctmAddresses.daAddresses.daContracts.rollupDAManager = deployWithCreate2AndOwner(
            "RollupDAManager",
            getDeployerAddress(),
            false
        );
        updateRollupDAManager();

        // This contract is located in the `da-contracts` folder, we output it the same way for consistency/ease of use.
        ctmAddresses.daAddresses.daContracts.rollupSLDAValidator = deploySimpleContract("RollupL1DAValidator", false);
        if (config.isZKsyncOS) {
            ctmAddresses.daAddresses.l1BlobsDAValidatorZKsyncOS = deploySimpleContract(
                "BlobsL1DAValidatorZKsyncOS",
                false
            );
        }

        ctmAddresses.daAddresses.daContracts.validiumDAValidator = deploySimpleContract("ValidiumL1DAValidator", false);

        if (config.contracts.availL1DAValidator == address(0)) {
            ctmAddresses.daAddresses.availBridge = deploySimpleContract("DummyAvailBridge", false);
            ctmAddresses.daAddresses.availL1DAValidator = deploySimpleContract("AvailL1DAValidator", false);
        } else {
            ctmAddresses.daAddresses.availL1DAValidator = config.contracts.availL1DAValidator;
        }
        vm.startBroadcast(getDeployerAddress());
        IRollupDAManager rollupDAManager = IRollupDAManager(ctmAddresses.daAddresses.daContracts.rollupDAManager);
        rollupDAManager.updateDAPair(
            ctmAddresses.daAddresses.daContracts.rollupSLDAValidator,
            getRollupL2DACommitmentScheme(),
            true
        );
        if (config.isZKsyncOS) {
            rollupDAManager.updateDAPair(
                ctmAddresses.daAddresses.l1BlobsDAValidatorZKsyncOS,
                getRollupL2DACommitmentScheme(),
                true
            );
        }
        vm.stopBroadcast();
    }

    function updateRollupDAManager() internal virtual {
        IOwnable rollupDAManager = IOwnable(ctmAddresses.daAddresses.daContracts.rollupDAManager);
        address deployer = getDeployerAddress();
        if (rollupDAManager.owner() != deployer) {
            if (rollupDAManager.pendingOwner() == deployer) {
                vm.broadcast(deployer);
                rollupDAManager.acceptOwnership();
            } else {
                require(rollupDAManager.owner() == config.ownerAddress, "Ownership was not set correctly");
            }
        }
    }

    function updateOwners() internal {
        vm.startBroadcast(getDeployerAddress());

        ValidatorTimelock validatorTimelock = ValidatorTimelock(ctmAddresses.stateTransition.proxies.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        IChainTypeManager ctm = IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager);
        IOwnable(address(ctm)).transferOwnership(ctmAddresses.admin.governance);
        ctm.setPendingAdmin(ctmAddresses.chainAdmin);

        IOwnable(ctmAddresses.stateTransition.proxies.serverNotifier).transferOwnership(ctmAddresses.chainAdmin);
        IOwnable(ctmAddresses.daAddresses.daContracts.rollupDAManager).transferOwnership(ctmAddresses.admin.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal virtual {
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "bridgehub_proxy_addr",
            coreAddresses.bridgehub.proxies.bridgehub
        );
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", coreAddresses.bridges.proxies.l1Nullifier);
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            coreAddresses.bridges.proxies.l1AssetRouter
        );
        // TODO(EVM-744): this has to be renamed to chain type manager
        vm.serializeAddress(
            "state_transition",
            "state_transition_proxy_addr",
            ctmAddresses.stateTransition.proxies.chainTypeManager
        );
        vm.serializeAddress("state_transition", "verifier_addr", ctmAddresses.stateTransition.verifiers.verifier);
        if (multiProofAddresses.airbenderVerifier != address(0)) {
            vm.serializeAddress("state_transition", "airbender_verifier_addr", multiProofAddresses.airbenderVerifier);
        }
        if (multiProofAddresses.ziskVerifier != address(0)) {
            vm.serializeAddress("state_transition", "zisk_verifier_addr", multiProofAddresses.ziskVerifier);
        }
        if (multiProofAddresses.ziskTestnetVerifier != address(0)) {
            vm.serializeAddress(
                "state_transition",
                "zisk_testnet_verifier_addr",
                multiProofAddresses.ziskTestnetVerifier
            );
        }
        if (multiProofAddresses.multiProofVerifier != address(0)) {
            vm.serializeAddress(
                "state_transition",
                "multi_proof_verifier_addr",
                multiProofAddresses.multiProofVerifier
            );
        }
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", ctmAddresses.stateTransition.genesisUpgrade);
        vm.serializeAddress("state_transition", "default_upgrade_addr", ctmAddresses.stateTransition.defaultUpgrade);
        vm.serializeAddress("state_transition", "eip7702_checker_addr", ctmAddresses.admin.eip7702Checker);
        vm.serializeAddress(
            "state_transition",
            "bytecodes_supplier_impl_addr",
            ctmAddresses.stateTransition.implementations.bytecodesSupplier
        );
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "bytecodes_supplier_addr",
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        );

        vm.serializeBytes("contracts_config", "diamond_cut_data", config.contracts.diamondCutData);

        string memory contractsConfig = vm.serializeBytes(
            "contracts_config",
            "force_deployments_data",
            generatedData.forceDeploymentsData
        );
        vm.serializeAddress(
            "deployed_addresses",
            "server_notifier_proxy_addr",
            ctmAddresses.stateTransition.proxies.serverNotifier
        );

        vm.serializeAddress("deployed_addresses", "governance_addr", ctmAddresses.admin.governance);
        vm.serializeAddress("deployed_addresses", "chain_admin", ctmAddresses.chainAdmin);
        vm.serializeString("deployed_addresses", "bridges", bridges);
        vm.serializeAddress(
            "deployed_addresses",
            "transparent_proxy_admin_addr",
            ctmAddresses.admin.transparentProxyAdmin
        );

        vm.serializeAddress(
            "deployed_addresses",
            "validator_timelock_addr",
            ctmAddresses.stateTransition.proxies.validatorTimelock
        );
        vm.serializeAddress(
            "deployed_addresses",
            "l1_rollup_da_manager",
            ctmAddresses.daAddresses.daContracts.rollupDAManager
        );
        vm.serializeAddress(
            "deployed_addresses",
            "rollup_l1_da_validator_addr",
            ctmAddresses.daAddresses.daContracts.rollupSLDAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "no_da_validium_l1_validator_addr",
            ctmAddresses.daAddresses.daContracts.validiumDAValidator
        );
        if (config.isZKsyncOS) {
            vm.serializeAddress(
                "deployed_addresses",
                "blobs_zksync_os_l1_da_validator_addr",
                ctmAddresses.daAddresses.l1BlobsDAValidatorZKsyncOS
            );
        }
        vm.serializeAddress(
            "deployed_addresses",
            "avail_l1_da_validator_addr",
            ctmAddresses.daAddresses.availL1DAValidator
        );
        string memory deployedAddresses = vm.serializeString("deployed_addresses", "state_transition", stateTransition);

        vm.serializeUint(
            "chain_creation_params",
            "latest_protocol_version",
            config.contracts.chainCreationParams.latestProtocolVersion
        );
        vm.serializeBytes32(
            "chain_creation_params",
            "bootloader_hash",
            config.contracts.chainCreationParams.bootloaderHash
        );
        vm.serializeBytes32(
            "chain_creation_params",
            "default_aa_hash",
            config.contracts.chainCreationParams.defaultAAHash
        );
        vm.serializeBytes32(
            "chain_creation_params",
            "evm_emulator_hash",
            config.contracts.chainCreationParams.evmEmulatorHash
        );
        vm.serializeBytes32("chain_creation_params", "genesis_root", config.contracts.chainCreationParams.genesisRoot);
        vm.serializeUint(
            "chain_creation_params",
            "genesis_rollup_leaf_index",
            config.contracts.chainCreationParams.genesisRollupLeafIndex
        );
        string memory chainCreationParams = vm.serializeBytes32(
            "chain_creation_params",
            "genesis_batch_commitment",
            config.contracts.chainCreationParams.genesisBatchCommitment
        );

        vm.serializeAddress("contracts", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        string memory contracts = vm.serializeBytes32("contracts", "create2_factory_salt", _create2FactorySalt);

        vm.serializeString("root", "chain_creation_params", chainCreationParams);
        vm.serializeAddress("root", "multicall3_addr", config.contracts.multicall3Addr);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts", contracts);
        vm.serializeBool("root", "is_zk_sync_os", config.isZKsyncOS);
        string memory toml = vm.serializeString("root", "contracts_config", contractsConfig);
        vm.writeToml(toml, outputPath);
    }

    function prepareForceDeploymentsData() internal returns (bytes memory) {
        require(ctmAddresses.admin.governance != address(0), "Governance address is not set");

        FixedForceDeploymentsData memory data = _buildForceDeploymentsData(ctmAddresses.admin.governance);

        return abi.encode(data);
    }

    /// @dev Scratch file for `_precomputeBlakeHashes`. Set by `runInner`
    ///      from the caller's output path; falls back to the conventional
    ///      fixed name for entrypoints that don't take paths.
    string private _blakeBatchTmpFile;

    /// @dev Precompute blake2s hashes for all unique bytecodes in a single FFI call.
    function _precomputeBlakeHashes() private {
        CoreContract[10] memory contracts = [
            CoreContract.L2Bridgehub,
            CoreContract.L2AssetRouter,
            CoreContract.L2NativeTokenVault,
            CoreContract.L2MessageRoot,
            CoreContract.UpgradeableBeaconDeployer,
            CoreContract.L2ChainAssetHandler,
            CoreContract.InteropCenter,
            CoreContract.L2InteropHandler,
            CoreContract.L2AssetTracker,
            CoreContract.BaseTokenHolder
        ];

        string memory tmpFile = bytes(_blakeBatchTmpFile).length != 0
            ? _blakeBatchTmpFile
            : string.concat(vm.projectRoot(), "/script-out/tmp-blake-batch.txt");
        vm.writeFile(tmpFile, "");

        bytes[10] memory bytecodes;
        for (uint256 i = 0; i < contracts.length; i++) {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, contracts[i]);
            bytecodes[i] = BytecodeUtils.readDeployedBytecodeL1(true, fileName, contractName);
            vm.writeLine(tmpFile, vm.toString(bytecodes[i]));
        }
        // Also add SystemContractProxy (used for proxy-upgrade bytecode info)
        bytes memory proxyBytecode = BytecodeUtils.readDeployedBytecodeL1(
            true,
            "SystemContractProxy.sol",
            "SystemContractProxy"
        );
        vm.writeLine(tmpFile, vm.toString(proxyBytecode));

        // Single FFI call to batch-hash all bytecodes
        string[] memory input = new string[](4);
        input[0] = "node";
        input[1] = "./scripts/blake2s256.js";
        input[2] = "--batch";
        input[3] = tmpFile;
        bytes memory result = vm.ffi(input);

        // The batch is the `contracts` list plus the SystemContractProxy appended above.
        uint256 totalBytecodes = contracts.length + 1;
        require(result.length == totalBytecodes * 32, "Unexpected batch blake2s result length");
        for (uint256 i = 0; i < contracts.length; i++) {
            bytes32 hash;
            assembly {
                hash := mload(add(result, add(32, mul(i, 32))))
            }
            _blakeCache[keccak256(bytecodes[i])] = hash;
        }
        {
            uint256 proxyIndex = contracts.length;
            bytes32 proxyHash;
            assembly {
                proxyHash := mload(add(result, add(32, mul(proxyIndex, 32))))
            }
            _blakeCache[keccak256(proxyBytecode)] = proxyHash;
        }

        vm.removeFile(tmpFile);
    }

    /// @dev Look up a pre-computed blake2s hash and build ZKSyncOSBytecodeInfo.
    function _cachedZKOSBytecodeInfo(bytes memory _bytecode) private view returns (bytes memory) {
        bytes32 key = keccak256(_bytecode);
        bytes32 blakeHash = _blakeCache[key];
        require(blakeHash != bytes32(0), "Blake hash not cached");
        return ZKSyncOSBytecodeInfo.encodeZKSyncOSBytecodeInfo(blakeHash, uint32(_bytecode.length), key);
    }

    /// @dev Returns proxy-upgrade bytecode info, using the blake cache when available.
    function _getProxyUpgradeBytecodeInfo(
        string memory _fileName,
        string memory _contractName
    ) private returns (bytes memory) {
        if (config.isZKsyncOS) {
            bytes memory implBytecode = BytecodeUtils.readDeployedBytecodeL1(true, _fileName, _contractName);
            bytes memory proxyBytecode = BytecodeUtils.readDeployedBytecodeL1(
                true,
                "SystemContractProxy.sol",
                "SystemContractProxy"
            );
            return abi.encode(_cachedZKOSBytecodeInfo(implBytecode), _cachedZKOSBytecodeInfo(proxyBytecode));
        }
        return CoreOnGatewayHelper.getBytecodeInfo(false, CoreContract.L2Bridgehub); // unreachable, but keeps compiler happy
    }

    /// @dev Get bytecode info, using cached blake hashes for ZKsyncOS or CoreOnGatewayHelper for Era.
    function _getBytecodeInfo(CoreContract _c) internal virtual returns (bytes memory) {
        if (config.isZKsyncOS) {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, _c);
            return _getProxyUpgradeBytecodeInfo(fileName, contractName);
        }
        return CoreOnGatewayHelper.getBytecodeInfo(false, _c);
    }

    function _buildForceDeploymentsData(
        address _governance
    ) internal virtual returns (FixedForceDeploymentsData memory data) {
        if (config.isZKsyncOS) {
            _precomputeBlakeHashes();
        }

        data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: coreAddresses.bridges.proxies.l1AssetRouter,
            l2TokenProxyBytecodeHash: CoreOnGatewayHelper.getDeployedBytecodeHash(
                config.isZKsyncOS,
                CoreContract.BeaconProxy
            ),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(_governance),
            maxNumberOfZKChains: config.contracts.maxNumberOfChains,
            bridgehubBytecodeInfo: _getBytecodeInfo(CoreContract.L2Bridgehub),
            l2AssetRouterBytecodeInfo: _getBytecodeInfo(CoreContract.L2AssetRouter),
            l2NtvBytecodeInfo: _getBytecodeInfo(CoreContract.L2NativeTokenVault),
            messageRootBytecodeInfo: _getBytecodeInfo(CoreContract.L2MessageRoot),
            beaconDeployerInfo: _getBytecodeInfo(CoreContract.UpgradeableBeaconDeployer),
            baseTokenHolderBytecodeInfo: _getBytecodeInfo(CoreContract.BaseTokenHolder),
            chainAssetHandlerBytecodeInfo: _getBytecodeInfo(CoreContract.L2ChainAssetHandler),
            interopCenterBytecodeInfo: _getBytecodeInfo(CoreContract.InteropCenter),
            interopHandlerBytecodeInfo: _getBytecodeInfo(CoreContract.L2InteropHandler),
            assetTrackerBytecodeInfo: _getBytecodeInfo(CoreContract.L2AssetTracker),
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            aliasedChainRegistrationSender: AddressAliasHelper.applyL1ToL2Alias(
                coreAddresses.bridgehub.proxies.chainRegistrationSender
            ),
            // Retained as address(0) for force-deployments ABI compatibility; the legacy forced beacon is gone.
            dangerousTestOnlyForcedBeacon: address(0),
            zkTokenAssetId: config.zkTokenAssetId
        });
    }

    function deployServerNotifier() internal returns (address implementation, address proxy) {
        // We will not store the address of the ProxyAdmin as it is trivial to query if needed.
        address ecosystemProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", ctmAddresses.chainAdmin, false);
        (implementation, proxy) = deployTuppWithContractAndProxyAdmin("ServerNotifier", ecosystemProxyAdmin, false);
    }

    function saveDiamondSelectors() public {
        AdminFacet adminFacet = new AdminFacet(block.chainid, RollupDAManager(address(0)));
        GettersFacet gettersFacet = new GettersFacet();
        MailboxFacet mailboxFacet = new MailboxFacet(
            block.chainid,
            coreAddresses.bridgehub.proxies.chainAssetHandler,
            IEIP7702Checker(address(1)),
            false
        );
        ExecutorFacet executorFacet = new ExecutorFacet();
        MigratorFacet migratorFacet = new MigratorFacet(1, false);
        CommitterFacet committerFacet = new CommitterFacet(1);
        bytes4[] memory adminFacetSelectors = Utils.getAllSelectors(address(adminFacet).code);
        bytes4[] memory gettersFacetSelectors = Utils.getAllSelectors(address(gettersFacet).code);
        bytes4[] memory mailboxFacetSelectors = Utils.getAllSelectors(address(mailboxFacet).code);
        bytes4[] memory executorFacetSelectors = Utils.getAllSelectors(address(executorFacet).code);
        bytes4[] memory migratorFacetSelectors = Utils.getAllSelectors(address(migratorFacet).code);
        bytes4[] memory committerFacetSelectors = Utils.getAllSelectors(address(committerFacet).code);

        string memory root = vm.projectRoot();
        string memory outputPath = string.concat(root, "/script-out/diamond-selectors.toml");

        bytes memory adminFacetSelectorsBytes = abi.encode(adminFacetSelectors);
        bytes memory gettersFacetSelectorsBytes = abi.encode(gettersFacetSelectors);
        bytes memory mailboxFacetSelectorsBytes = abi.encode(mailboxFacetSelectors);
        bytes memory executorFacetSelectorsBytes = abi.encode(executorFacetSelectors);
        bytes memory migratorFacetSelectorsBytes = abi.encode(migratorFacetSelectors);
        bytes memory committerFacetSelectorsBytes = abi.encode(committerFacetSelectors);

        vm.serializeBytes("diamond_selectors", "admin_facet_selectors", adminFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "getters_facet_selectors", gettersFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "mailbox_facet_selectors", mailboxFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "executor_facet_selectors", executorFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "migrator_facet_selectors", migratorFacetSelectorsBytes);
        string memory toml = vm.serializeBytes(
            "diamond_selectors",
            "committer_facet_selectors",
            committerFacetSelectorsBytes
        );

        vm.writeToml(toml, outputPath);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
