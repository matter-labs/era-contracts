// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS, ADDRESS_ONE} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {VerifierFflonk} from "contracts/state-transition/verifiers/VerifierFflonk.sol";
import {VerifierPlonk} from "contracts/state-transition/verifiers/VerifierPlonk.sol";
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
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";

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
    // The forced beacon address. It is needed only for internal testing.
    // MUST be equal to 0 in production.
    // It will be the job of the governance to ensure that this value is set correctly.
    address dangerousTestOnlyForcedBeacon;
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
    address create2Factory;
    address chainRegistrar;
}

// solhint-disable-next-line gas-struct-packing
struct L1NativeTokenVaultAddresses {
    address l1NativeTokenVaultImplementation;
    address l1NativeTokenVaultProxy;
}

struct DataAvailabilityDeployedAddresses {
    address rollupDAManager;
    address l1RollupDAValidator;
    address noDAValidiumL1DAValidator;
    address availBridge;
    address availL1DAValidator;
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
    address l1AssetRouterImplementation;
    address l1AssetRouterProxy;
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
    bool supportL2LegacySharedBridgeTest;
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
    bytes32 evmEmulatorHash;
    address availL1DAValidator;
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

    function initializeConfig(string memory configPath) internal virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");
        config.supportL2LegacySharedBridgeTest = toml.readBool("$.support_l2_legacy_shared_bridge_test");

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
        config.contracts.evmEmulatorHash = toml.readBytes32("$.contracts.evm_emulator_hash");

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }

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

    function deployStateTransitionDiamondFacets() internal {
        addresses.stateTransition.executorFacet = deploySimpleContract("ExecutorFacet");
        addresses.stateTransition.adminFacet = deploySimpleContract("AdminFacet");
        addresses.stateTransition.mailboxFacet = deploySimpleContract("MailboxFacet");
        addresses.stateTransition.gettersFacet = deploySimpleContract("GettersFacet");
        addresses.stateTransition.diamondInit = deploySimpleContract("DiamondInit");
    }

    /// @notice Get new facet cuts
    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });
    }

    function getDiamondCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (Diamond.DiamondCutData memory diamondCut) {
        Diamond.FacetCut[] memory facetCuts = getFacetCuts(stateTransition);

        DiamondInitializeDataNewChain memory initializeData = getInitializeData(stateTransition);

        diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });
        if (!stateTransition.isOnGateway) {
            config.contracts.diamondCutData = abi.encode(diamondCut);
        }
    }

    function getChainCreationParams(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainCreationParams memory) {
        Diamond.DiamondCutData memory diamondCut = getDiamondCutData(stateTransition);
        return
            ChainCreationParams({
                genesisUpgrade: stateTransition.genesisUpgrade,
                genesisBatchHash: config.contracts.genesisRoot,
                genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
                genesisBatchCommitment: config.contracts.genesisBatchCommitment,
                diamondCut: diamondCut,
                forceDeploymentsData: generatedData.forceDeploymentsData
            });
    }

    function getChainTypeManagerInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainTypeManagerInitializeData memory) {
        ChainCreationParams memory chainCreationParams = getChainCreationParams(stateTransition);
        return
            ChainTypeManagerInitializeData({
                owner: msg.sender,
                validatorTimelock: stateTransition.validatorTimelock,
                chainCreationParams: chainCreationParams,
                protocolVersion: config.contracts.latestProtocolVersion
            });
    }

    function getVerifierParams() internal returns (VerifierParams memory) {
        return
            VerifierParams({
                recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
                recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
                recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
            });
    }

    function getFeeParams() internal returns (FeeParams memory) {
        return
            FeeParams({
                pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
                batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
                maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
                maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
                priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
                minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
            });
    }

    function getInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (DiamondInitializeDataNewChain memory) {
        VerifierParams memory verifierParams = getVerifierParams();

        FeeParams memory feeParams = getFeeParams();

        return
            DiamondInitializeDataNewChain({
                verifier: IVerifier(stateTransition.verifier),
                verifierParams: verifierParams,
                l2BootloaderBytecodeHash: config.contracts.bootloaderHash,
                l2DefaultAccountBytecodeHash: config.contracts.defaultAAHash,
                l2EvmEmulatorBytecodeHash: config.contracts.evmEmulatorHash,
                priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
                feeParams: feeParams,
                blobVersionedHashRetriever: stateTransition.isOnGateway
                    ? ADDRESS_ONE
                    : addresses.blobVersionedHashRetriever
            });
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function deploySimpleContract(string memory contractName) internal returns (address contractAddress) {
        contractAddress = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            contractName
        );
    }

    function deployWithCreate2AndOwner(
        string memory contractName,
        address owner
    ) internal returns (address contractAddress) {
        contractAddress = deployWithOwnerAndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            owner,
            contractName,
            string.concat(contractName, " Implementation")
        );
    }

    function deployTuppWithContract(
        string memory contractName
    ) internal virtual returns (address implementation, address proxy) {
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            contractName,
            string.concat(contractName, " Implementation")
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, addresses.transparentProxyAdmin, getInitializeCalldata(contractName)),
            contractName,
            string.concat(contractName, " Proxy")
        );
        return (implementation, proxy);
    }

    ////////////////////////////// GetContract data  /////////////////////////////////

    function getCreationCode(string memory contractName) internal view virtual returns (bytes memory) {
        if (compareStrings(contractName, "Verifier")) {
            if (config.testnetVerifier) {
                return type(TestnetVerifier).creationCode;
            } else {
                return type(DualVerifier).creationCode;
            }
        } else if (compareStrings(contractName, "VerifierFflonk")) {
            return type(VerifierFflonk).creationCode;
        } else if (compareStrings(contractName, "VerifierPlonk")) {
            return type(VerifierPlonk).creationCode;
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return type(DefaultUpgrade).creationCode;
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return type(L1GenesisUpgrade).creationCode;
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return type(ValidatorTimelock).creationCode;
        } else if (compareStrings(contractName, "Governance")) {
            return type(Governance).creationCode;
        } else if (compareStrings(contractName, "ChainAdminOwnable")) {
            return type(ChainAdminOwnable).creationCode;
        } else if (compareStrings(contractName, "AccessControlRestriction")) {
            // TODO(EVM-924): this function is unused
            return type(AccessControlRestriction).creationCode;
        } else if (compareStrings(contractName, "ChainAdmin")) {
            return type(ChainAdmin).creationCode;
        } else if (compareStrings(contractName, "ChainTypeManager")) {
            return type(ChainTypeManager).creationCode;
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return type(BytecodesSupplier).creationCode;
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return type(ProxyAdmin).creationCode;
        } else if (compareStrings(contractName, "ExecutorFacet")) {
            return type(ExecutorFacet).creationCode;
        } else if (compareStrings(contractName, "AdminFacet")) {
            return type(AdminFacet).creationCode;
        } else if (compareStrings(contractName, "MailboxFacet")) {
            return type(MailboxFacet).creationCode;
        } else if (compareStrings(contractName, "GettersFacet")) {
            return type(GettersFacet).creationCode;
        } else if (compareStrings(contractName, "DiamondInit")) {
            return type(DiamondInit).creationCode;
        } else {
            revert(string.concat("Contract ", contractName, " creation code not set"));
        }
    }
    function getCreationCalldata(string memory contractName) internal view virtual returns (bytes memory) {
        if (compareStrings(contractName, "Verifier")) {
            return abi.encode(addresses.stateTransition.verifierFflonk, addresses.stateTransition.verifierPlonk);
        } else if (compareStrings(contractName, "VerifierFflonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "VerifierPlonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
            return abi.encode(config.deployerAddress, executionDelay, config.eraChainId);
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
            restrictions[0] = addresses.accessControlRestrictionAddress;
            return abi.encode(restrictions);
        } else if (compareStrings(contractName, "ChainTypeManager")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy);
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ExecutorFacet")) {
            return abi.encode(config.l1ChainId);
        } else if (compareStrings(contractName, "AdminFacet")) {
            return abi.encode(config.l1ChainId, addresses.daAddresses.rollupDAManager);
        } else if (compareStrings(contractName, "MailboxFacet")) {
            return abi.encode(config.eraChainId, config.l1ChainId);
        } else if (compareStrings(contractName, "GettersFacet")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DiamondInit")) {
            return abi.encode();
        } else {
            revert(string.concat("Contract ", contractName, " creation calldata not set"));
        }
    }

    function getInitializeCalldata(string memory contractName) internal virtual returns (bytes memory) {
        if (compareStrings(contractName, "ChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManager.initialize,
                    getChainTypeManagerInitializeData(addresses.stateTransition)
                );
        } else {
            revert(string.concat("Contract ", contractName, " initialize calldata not set"));
        }
    }

    function getDeployedContractName(string memory contractName) internal view virtual returns (string memory) {
        if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return "UpgradeableBeacon";
        } else {
            return contractName;
        }
    }

    ////////////////////////////// Create2 utils /////////////////////////////////

    function deployViaCreate2AndNotify(
        bytes memory _creationCode,
        bytes memory _constructorParamsEncoded,
        string memory contractName
    ) internal returns (address deployedAddress) {
        deployedAddress = deployViaCreate2AndNotify(
            _creationCode,
            _constructorParamsEncoded,
            contractName,
            contractName
        );
    }

    function deployViaCreate2AndNotify(
        bytes memory _creationCode,
        bytes memory _constructorParamsEncoded,
        string memory contractName,
        string memory displayName
    ) internal returns (address deployedAddress) {
        bytes memory bytecode = abi.encodePacked(_creationCode, _constructorParamsEncoded);

        deployedAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(deployedAddress, contractName, _constructorParamsEncoded, displayName);
    }

    function deployWithOwnerAndNotify(
        bytes memory initCode,
        bytes memory constructorParams,
        address owner,
        string memory contractName,
        string memory displayName
    ) internal returns (address contractAddress) {
        contractAddress = create2WithDeterministicOwner(abi.encodePacked(initCode, constructorParams), owner);
        notifyAboutDeployment(contractAddress, contractName, constructorParams, displayName);
    }

    function create2WithDeterministicOwner(bytes memory initCode, address owner) internal returns (address) {
        bytes memory creatorInitCode = abi.encodePacked(
            type(Create2AndTransfer).creationCode,
            abi.encode(initCode, config.contracts.create2FactorySalt, owner)
        );

        address deployerAddr = deployViaCreate2(creatorInitCode);

        return Create2AndTransfer(deployerAddr).deployedAddress();
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.contracts.create2FactorySalt, addresses.create2Factory);
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

    ////////////////////////////// Misc utils /////////////////////////////////

    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams
    ) internal {
        notifyAboutDeployment(contractAddr, contractName, constructorParams, contractName);
    }

    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        string memory displayName
    ) internal {
        string memory basicMessage = string.concat(displayName, " has been deployed at ", vm.toString(contractAddr));
        console.log(basicMessage);

        string memory forgeMessage;
        string memory deployedContractName = getDeployedContractName(contractName);
        if (constructorParams.length == 0) {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                deployedContractName
            );
        } else {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                deployedContractName,
                " --constructor-args ",
                vm.toString(constructorParams)
            );
        }

        console.log(forgeMessage);
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function test() internal virtual {}
}
