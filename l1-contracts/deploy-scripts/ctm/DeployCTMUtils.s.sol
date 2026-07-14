// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";
import {console2 as console} from "forge-std/Script.sol";

import {ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainCreationParams} from "contracts/state-transition/ILegacyChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {CTMRegistry} from "contracts/upgrades/registry/CTMRegistry.sol";
import {GenesisManifestLib} from "contracts/upgrades/registry/GenesisManifestLib.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
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

import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
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
import {EraSettlementLayerV31Upgrade} from "contracts/upgrades/EraSettlementLayerV31Upgrade.sol";
import {ZKsyncOSSettlementLayerV31Upgrade} from "contracts/upgrades/ZKsyncOSSettlementLayerV31Upgrade.sol";

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address deployerAddress;
    uint256 eraChainId;
    uint256 gatewayChainId;
    address ownerAddress;
    bytes32 zkTokenAssetId;
    bool testnetVerifier;
    bool supportL2LegacySharedBridgeTest;
    bool isZKsyncOS;
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

    //slither-disable-next-line reentrancy-benign
    function deployStateTransitionDiamondFacets() internal {
        ctmAddresses.stateTransition.facets.executorFacet = deploySimpleContract("ExecutorFacet", false);
        ctmAddresses.stateTransition.facets.adminFacet = deploySimpleContract("AdminFacet", false);
        ctmAddresses.stateTransition.facets.mailboxFacet = deploySimpleContract("MailboxFacet", false);
        ctmAddresses.stateTransition.facets.gettersFacet = deploySimpleContract("GettersFacet", false);
        ctmAddresses.stateTransition.facets.migratorFacet = deploySimpleContract("MigratorFacet", false);
        ctmAddresses.stateTransition.facets.committerFacet = deploySimpleContract("CommitterFacet", false);
        ctmAddresses.stateTransition.facets.diamondInit = deploySimpleContract("DiamondInit", false);
        ctmAddresses.stateTransition.genesisRegistry = deployGenesisRegistry();
    }

    /// @notice Deploys the storage-backed genesis registry and pins the freshly deployed facet
    /// set plus the base system contract hashes into it. The chain-creation params point at it
    /// (`ChainCreationParams.registry`), and `DiamondInit` reads everything chain-independent
    /// from there — the committed genesis cut carries no facets and no init payload.
    /// @dev Plain CREATE, not CREATE2: the registry has no constructor args, so a CREATE2 deploy
    /// with the shared salt would land every run (Era CTM, ZKsyncOS CTM, later upgrades) on the
    /// same, already-initialized address. A deterministic address buys nothing here — the CTM
    /// stores the pointer — and the manifest hash is verified after initialization.
    function deployGenesisRegistry() internal returns (address) {
        if (!config.isZKsyncOS) {
            require(config.contracts.chainCreationParams.bootloaderHash != bytes32(0), "bootloader hash is zero");
            require(
                config.contracts.chainCreationParams.defaultAAHash != bytes32(0),
                "default account abstraction hash is zero"
            );
            require(config.contracts.chainCreationParams.evmEmulatorHash != bytes32(0), "EVM emulator hash is zero");
        }

        require(generatedData.forceDeploymentsData.length != 0, "force deployments data is empty");
        CTMRegistry.CTMRegistryManifest memory manifest = GenesisManifestLib.buildGenesisManifest(
            GenesisManifestLib.GenesisConfig({
                isZKsyncOS: config.isZKsyncOS,
                protocolVersion: config.contracts.chainCreationParams.latestProtocolVersion,
                facets: ctmAddresses.stateTransition.facets,
                bootloaderHash: config.contracts.chainCreationParams.bootloaderHash,
                defaultAccountHash: config.contracts.chainCreationParams.defaultAAHash,
                evmEmulatorHash: config.contracts.chainCreationParams.evmEmulatorHash,
                genesisUpgrade: ctmAddresses.stateTransition.genesisUpgrade,
                genesisBatchHash: config.contracts.chainCreationParams.genesisRoot,
                genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
                genesisIndexRepeatedStorageChanges: uint64(config.contracts.chainCreationParams.genesisRollupLeafIndex),
                fixedForceDeploymentsData: generatedData.forceDeploymentsData
            })
        );

        vm.broadcast(getBroadcasterAddress());
        CTMRegistry registry = new CTMRegistry();

        vm.broadcast(getBroadcasterAddress());
        registry.initialize(manifest);

        // The initializer is unauthenticated (one-shot, no constructor), so confirm nobody
        // front-ran it with different contents before this address gets pinned anywhere.
        require(registry.manifestHash() == keccak256(abi.encode(manifest)), "genesis registry manifest mismatch");

        console.log("Bootstrap CTMRegistry (genesis) deployed at:", address(registry));
        return address(registry);
    }

    function chainCreationParamsPath(bool _isZKsyncOS) internal virtual returns (string memory) {
        return Utils.genesisConfigPath(_isZKsyncOS);
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

        config.supportL2LegacySharedBridgeTest = toml.readBool("$.support_l2_legacy_shared_bridge_test");
        if (toml.keyExists("$.is_zk_sync_os")) {
            config.isZKsyncOS = toml.readBool("$.is_zk_sync_os");
        }
        if (toml.keyExists("$.era_chain_id")) {
            config.eraChainId = toml.readUint("$.era_chain_id");
        }
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
        config.contracts.chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath(config.isZKsyncOS));

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }
    }

    function getChainCreationParamsConfig(
        string memory _config
    ) internal virtual returns (ChainCreationParamsConfig memory chainCreationParams) {
        return ChainCreationParamsLib.getChainCreationParams(_config, config.isZKsyncOS);
    }

    function getChainCreationDiamondCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (Diamond.DiamondCutData memory diamondCut) {
        // The committed genesis cut is only the DiamondInit address: no `facetCuts` and no init
        // payload. `DiamondInit` reads the facet set and the base system contract hashes from
        // the genesis registry pinned in `ChainCreationParams.registry` below.
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
        require(stateTransition.genesisRegistry != address(0), "genesis registry is not deployed");
        Diamond.DiamondCutData memory diamondCut = getChainCreationDiamondCutData(stateTransition);
        config.contracts.diamondCutData = abi.encode(diamondCut);
        return
            ChainCreationParams({
                genesisUpgrade: stateTransition.genesisUpgrade,
                genesisBatchHash: config.contracts.chainCreationParams.genesisRoot,
                genesisIndexRepeatedStorageChanges: uint64(config.contracts.chainCreationParams.genesisRollupLeafIndex),
                genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
                diamondCut: diamondCut,
                forceDeploymentsData: generatedData.forceDeploymentsData,
                registry: stateTransition.genesisRegistry
            });
    }

    function getChainTypeManagerInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainTypeManagerInitializeData memory) {
        require(stateTransition.genesisRegistry != address(0), "genesis registry is not deployed");
        // Populate `config.contracts.diamondCutData` (a legacy output field) for serialization.
        getChainCreationParams(stateTransition);
        return
            ChainTypeManagerInitializeData({
                owner: getBroadcasterAddress(),
                validatorTimelock: stateTransition.proxies.validatorTimelock,
                genesisRegistry: stateTransition.genesisRegistry,
                protocolVersion: config.contracts.chainCreationParams.latestProtocolVersion,
                verifier: stateTransition.verifiers.verifier,
                serverNotifier: stateTransition.proxies.serverNotifier
            });
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            return ContractsBytecodesLib.getCreationCodeEVM(contractName);
        }
        return ContractsBytecodesLib.getL2Bytecode(contractName, config.isZKsyncOS);
    }

    function getRollupL2DACommitmentScheme() internal returns (L2DACommitmentScheme) {
        return ROLLUP_L2_DA_COMMITMENT_SCHEME;
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
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
        } else if (
            compareStrings(contractName, "EraVerifierFflonk") || compareStrings(contractName, "ZKsyncOSVerifierFflonk")
        ) {
            return abi.encode();
        } else if (
            compareStrings(contractName, "EraVerifierPlonk") || compareStrings(contractName, "ZKsyncOSVerifierPlonk")
        ) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return abi.encode();
        } else if (
            compareStrings(contractName, "EraSettlementLayerV31Upgrade") ||
            compareStrings(contractName, "ZKsyncOSSettlementLayerV31Upgrade") ||
            compareStrings(contractName, "SettlementLayerV32Upgrade")
        ) {
            return abi.encode();
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
                    config.isZKsyncOS,
                    DeployCTML1OrGateway.getCTMContractFromName(contractName),
                    isZKBytecode
                );
        }
    }

    function getCTMCoreDeploymentConfig(Config memory _config) internal view returns (CTMCoreDeploymentConfig memory) {
        return
            CTMCoreDeploymentConfig({
                isZKsyncOS: _config.isZKsyncOS,
                testnetVerifier: _config.testnetVerifier,
                eraChainId: _config.eraChainId,
                l1ChainId: _config.l1ChainId,
                bridgehubProxy: coreAddresses.bridgehub.proxies.bridgehub,
                interopCenterProxy: L2_INTEROP_CENTER_ADDR,
                rollupDAManager: ctmAddresses.daAddresses.daContracts.rollupDAManager,
                chainAssetHandler: coreAddresses.bridgehub.proxies.chainAssetHandler,
                l1BytecodesSupplier: ctmAddresses.stateTransition.proxies.bytecodesSupplier,
                eip7702Checker: ctmAddresses.admin.eip7702Checker,
                verifierFflonk: ctmAddresses.stateTransition.verifiers.verifierFflonk,
                verifierPlonk: ctmAddresses.stateTransition.verifiers.verifierPlonk,
                // For L1 deployment we need to use the deployer as the owner of the verifier,
                // because we set the dual verifier later. Use getBroadcasterAddress() to get
                // the actual EOA when this is called from a contract created via `new` during the script.
                verifierOwner: getBroadcasterAddress(),
                permissionlessValidator: ctmAddresses.stateTransition.proxies.permissionlessValidator
            });
    }

    function getL2BytecodeHash(string memory contractName) public view virtual returns (bytes32) {
        return L2ContractHelper.hashL2Bytecode(getCreationCode(contractName, true));
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "EraChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManagerBase.initialize,
                    getChainTypeManagerInitializeData(ctmAddresses.stateTransition)
                );
        } else if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
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
