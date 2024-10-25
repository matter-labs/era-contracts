// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "./ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";

struct FixedForceDeploymentsData {
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedL1Governance;
    uint256 maxNumberOfZKChains;
    bytes32 bridgehubBytecodeHash;
    bytes32 l2AssetRouterBytecodeHash;
    bytes32 l2NtvBytecodeHash;
    bytes32 messageRootBytecodeHash;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
}

// solhint-disable-next-line gas-struct-packing
struct DeployedAddresses {
    BridgehubDeployedAddresses bridgehub;
    StateTransitionDeployedAddresses stateTransition;
    BridgesDeployedAddresses bridges;
    L1NativeTokenVaultAddresses vaults;
    DataAvailabilityDeployedAddresses daAddresses;
    address transparentProxyAdmin;
    address governance;
    address chainAdmin;
    address accessControlRestrictionAddress;
    address blobVersionedHashRetriever;
    address validatorTimelock;
    address create2Factory;
}

// solhint-disable-next-line gas-struct-packing
struct L1NativeTokenVaultAddresses {
    address l1NativeTokenVaultImplementation;
    address l1NativeTokenVaultProxy;
}

struct DataAvailabilityDeployedAddresses {
    address rollupDAManager;
    address l1RollupDAValidator;
    address l1ValidiumDAValidator;
}

// solhint-disable-next-line gas-struct-packing
struct BridgehubDeployedAddresses {
    address bridgehubImplementation;
    address bridgehubProxy;
    address ctmDeploymentTrackerImplementation;
    address ctmDeploymentTrackerProxy;
    address messageRootImplementation;
    address messageRootProxy;
}

// solhint-disable-next-line gas-struct-packing
struct BridgesDeployedAddresses {
    address erc20BridgeImplementation;
    address erc20BridgeProxy;
    address sharedBridgeImplementation;
    address sharedBridgeProxy;
    address l1NullifierImplementation;
    address l1NullifierProxy;
    address bridgedStandardERC20Implementation;
    address bridgedTokenBeacon;
}

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address deployerAddress;
    uint256 eraChainId;
    address ownerAddress;
    bool testnetVerifier;
    ContractsConfig contracts;
    TokensConfig tokens;
}

// solhint-disable-next-line gas-struct-packing
struct ContractsConfig {
    bytes32 create2FactorySalt;
    address create2FactoryAddr;
    address multicall3Addr;
    uint256 validatorTimelockExecutionDelay;
    bytes32 genesisRoot;
    uint256 genesisRollupLeafIndex;
    bytes32 genesisBatchCommitment;
    uint256 latestProtocolVersion;
    bytes32 recursionNodeLevelVkHash;
    bytes32 recursionLeafLevelVkHash;
    bytes32 recursionCircuitsSetVksHash;
    uint256 priorityTxMaxGasLimit;
    PubdataPricingMode diamondInitPubdataPricingMode;
    uint256 diamondInitBatchOverheadL1Gas;
    uint256 diamondInitMaxPubdataPerBatch;
    uint256 diamondInitMaxL2GasPerBatch;
    uint256 diamondInitPriorityTxMaxPubdata;
    uint256 diamondInitMinimalL2GasPrice;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    uint256 maxNumberOfChains;
    bytes diamondCutData;
    bytes32 bootloaderHash;
    bytes32 defaultAAHash;
}

struct TokensConfig {
    address tokenWethAddress;
}

// solhint-disable-next-line gas-struct-packing
struct GeneratedData {
    bytes forceDeploymentsData;
}

contract DeployUtils is Script {
    using stdToml for string;

    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    Config public config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    function initializeConfig(string memory configPath) internal {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

        config.contracts.governanceSecurityCouncilAddress = toml.readAddress(
            "$.contracts.governance_security_council_address"
        );
        config.contracts.governanceMinDelay = toml.readUint("$.contracts.governance_min_delay");
        config.contracts.maxNumberOfChains = toml.readUint("$.contracts.max_number_of_chains");
        config.contracts.create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            config.contracts.create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        config.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.genesisRoot = toml.readBytes32("$.contracts.genesis_root");
        config.contracts.genesisRollupLeafIndex = toml.readUint("$.contracts.genesis_rollup_leaf_index");
        config.contracts.genesisBatchCommitment = toml.readBytes32("$.contracts.genesis_batch_commitment");
        config.contracts.latestProtocolVersion = toml.readUint("$.contracts.latest_protocol_version");
        config.contracts.recursionNodeLevelVkHash = toml.readBytes32("$.contracts.recursion_node_level_vk_hash");
        config.contracts.recursionLeafLevelVkHash = toml.readBytes32("$.contracts.recursion_leaf_level_vk_hash");
        config.contracts.recursionCircuitsSetVksHash = toml.readBytes32("$.contracts.recursion_circuits_set_vks_hash");
        config.contracts.priorityTxMaxGasLimit = toml.readUint("$.contracts.priority_tx_max_gas_limit");
        config.contracts.diamondInitPubdataPricingMode = PubdataPricingMode(
            toml.readUint("$.contracts.diamond_init_pubdata_pricing_mode")
        );
        config.contracts.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.contracts.diamond_init_batch_overhead_l1_gas"
        );
        config.contracts.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_pubdata_per_batch"
        );
        config.contracts.diamondInitMaxL2GasPerBatch = toml.readUint("$.contracts.diamond_init_max_l2_gas_per_batch");
        config.contracts.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.contracts.diamond_init_priority_tx_max_pubdata"
        );
        config.contracts.diamondInitMinimalL2GasPrice = toml.readUint("$.contracts.diamond_init_minimal_l2_gas_price");
        config.contracts.defaultAAHash = toml.readBytes32("$.contracts.default_aa_hash");
        config.contracts.bootloaderHash = toml.readBytes32("$.contracts.bootloader_hash");

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
    }

    function instantiateCreate2Factory() internal {
        address contractAddress;

        bool isDeterministicDeployed = DETERMINISTIC_CREATE2_ADDRESS.code.length > 0;
        bool isConfigured = config.contracts.create2FactoryAddr != address(0);

        if (isConfigured) {
            if (config.contracts.create2FactoryAddr.code.length == 0) {
                revert AddressHasNoCode(config.contracts.create2FactoryAddr);
            }
            contractAddress = config.contracts.create2FactoryAddr;
            console.log("Using configured Create2Factory address:", contractAddress);
        } else if (isDeterministicDeployed) {
            contractAddress = DETERMINISTIC_CREATE2_ADDRESS;
            console.log("Using deterministic Create2Factory address:", contractAddress);
        } else {
            contractAddress = Utils.deployCreate2Factory();
            console.log("Create2Factory deployed at:", contractAddress);
        }

        addresses.create2Factory = contractAddress;
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual returns (address) {
        return
            Utils.deployViaCreate2(
                abi.encodePacked(creationCode, constructorArgs),
                config.contracts.create2FactorySalt,
                addresses.create2Factory
            );
    }

    function deployBytecodesSupplier() internal {
        address contractAddress = deployViaCreate2(type(BytecodesSupplier).creationCode, "");
        console.log("BytecodesSupplier deployed at:", contractAddress);
        addresses.stateTransition.bytecodesSupplier = contractAddress;
    }

    function deployVerifier() internal {
        bytes memory code;
        if (config.testnetVerifier) {
            code = type(TestnetVerifier).creationCode;
        } else {
            code = type(Verifier).creationCode;
        }
        address contractAddress = deployViaCreate2(code, "");
        console.log("Verifier deployed at:", contractAddress);
        addresses.stateTransition.verifier = contractAddress;
    }

    function deployDefaultUpgrade() internal {
        address contractAddress = deployViaCreate2(type(DefaultUpgrade).creationCode, "");
        console.log("DefaultUpgrade deployed at:", contractAddress);
        addresses.stateTransition.defaultUpgrade = contractAddress;
    }

    function deployGenesisUpgrade() internal {
        address contractAddress = deployViaCreate2(type(L1GenesisUpgrade).creationCode, "");
        console.log("GenesisUpgrade deployed at:", contractAddress);
        addresses.stateTransition.genesisUpgrade = contractAddress;
    }

    function deployValidatorTimelock() internal {
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        address contractAddress = deployViaCreate2(
            type(ValidatorTimelock).creationCode,
            abi.encode(config.deployerAddress, executionDelay, config.eraChainId)
        );
        console.log("ValidatorTimelock deployed at:", contractAddress);
        addresses.validatorTimelock = contractAddress;
    }

    function deployGovernance() internal {
        address contractAddress = deployViaCreate2(
            type(Governance).creationCode,
            abi.encode(
                config.ownerAddress,
                config.contracts.governanceSecurityCouncilAddress,
                config.contracts.governanceMinDelay
            )
        );
        console.log("Governance deployed at:", contractAddress);
        addresses.governance = contractAddress;
    }

    function deployChainAdmin() internal {
        address accessControlRestriction = deployViaCreate2(
            type(AccessControlRestriction).creationCode,
            abi.encode(uint256(0), config.ownerAddress)
        );

        console.log("Access control restriction deployed at:", accessControlRestriction);
        address[] memory restrictions = new address[](1);
        restrictions[0] = accessControlRestriction;
        addresses.accessControlRestrictionAddress = accessControlRestriction;

        address contractAddress = deployViaCreate2(type(ChainAdmin).creationCode, abi.encode(restrictions));
        console.log("ChainAdmin deployed at:", contractAddress);
        addresses.chainAdmin = contractAddress;
    }

    function deployTransparentProxyAdmin() internal {
        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(addresses.governance);
        vm.stopBroadcast();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        addresses.transparentProxyAdmin = address(proxyAdmin);
    }

    function deployChainTypeManagerContract(address _rollupDAManager) internal {
        deployStateTransitionDiamondFacets(_rollupDAManager);
        deployChainTypeManagerImplementation();
        deployChainTypeManagerProxy();
    }

    function deployStateTransitionDiamondFacets(address _rollupDAManager) internal {
        address executorFacet = deployViaCreate2(type(ExecutorFacet).creationCode, abi.encode(config.l1ChainId));
        console.log("ExecutorFacet deployed at:", executorFacet);
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(
            type(AdminFacet).creationCode,
            abi.encode(config.l1ChainId, _rollupDAManager)
        );
        console.log("AdminFacet deployed at:", adminFacet);
        addresses.stateTransition.adminFacet = adminFacet;

        address mailboxFacet = deployViaCreate2(
            type(MailboxFacet).creationCode,
            abi.encode(config.eraChainId, config.l1ChainId)
        );
        console.log("MailboxFacet deployed at:", mailboxFacet);
        addresses.stateTransition.mailboxFacet = mailboxFacet;

        address gettersFacet = deployViaCreate2(type(GettersFacet).creationCode, "");
        console.log("GettersFacet deployed at:", gettersFacet);
        addresses.stateTransition.gettersFacet = gettersFacet;

        address diamondInit = deployViaCreate2(type(DiamondInit).creationCode, "");
        console.log("DiamondInit deployed at:", diamondInit);
        addresses.stateTransition.diamondInit = diamondInit;
    }

    function deployChainTypeManagerImplementation() internal {
        bytes memory bytecode = type(ChainTypeManager).creationCode;
        bytes memory constructorArgs = abi.encode(addresses.bridgehub.bridgehubProxy);
        address contractAddress = deployViaCreate2(bytecode, constructorArgs);
        console.log("ChainTypeManagerImplementation deployed at:", contractAddress);
        addresses.stateTransition.chainTypeManagerImplementation = contractAddress;
    }

    function deployChainTypeManagerProxy() internal {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(root, "/script-out/diamond-selectors.toml");
        string memory toml = vm.readFile(inputPath);

        bytes memory adminFacetSelectors = toml.readBytes("$.admin_facet_selectors");
        bytes memory gettersFacetSelectors = toml.readBytes("$.getters_facet_selectors");
        bytes memory mailboxFacetSelectors = toml.readBytes("$.mailbox_facet_selectors");
        bytes memory executorFacetSelectors = toml.readBytes("$.executor_facet_selectors");

        bytes4[] memory adminFacetSelectorsArray = abi.decode(adminFacetSelectors, (bytes4[]));
        bytes4[] memory gettersFacetSelectorsArray = abi.decode(gettersFacetSelectors, (bytes4[]));
        bytes4[] memory mailboxFacetSelectorsArray = abi.decode(mailboxFacetSelectors, (bytes4[]));
        bytes4[] memory executorFacetSelectorsArray = abi.decode(executorFacetSelectors, (bytes4[]));

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: addresses.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: adminFacetSelectorsArray
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: addresses.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: gettersFacetSelectorsArray
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: addresses.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: mailboxFacetSelectorsArray
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: addresses.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: executorFacetSelectorsArray
        });

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
        });

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
            batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
            maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
            maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
            priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
            minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(addresses.stateTransition.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: config.contracts.bootloaderHash,
            l2DefaultAccountBytecodeHash: config.contracts.defaultAAHash,
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            feeParams: feeParams,
            blobVersionedHashRetriever: addresses.blobVersionedHashRetriever
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        config.contracts.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: generatedData.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: msg.sender,
            validatorTimelock: addresses.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: config.contracts.latestProtocolVersion
        });

        address contractAddress = deployViaCreate2(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                addresses.stateTransition.chainTypeManagerImplementation,
                addresses.transparentProxyAdmin,
                abi.encodeCall(ChainTypeManager.initialize, (diamondInitData))
            )
        );
        console.log("ChainTypeManagerProxy deployed at:", contractAddress);
        addresses.stateTransition.chainTypeManagerProxy = contractAddress;
    }

    function test() internal virtual {}
}
