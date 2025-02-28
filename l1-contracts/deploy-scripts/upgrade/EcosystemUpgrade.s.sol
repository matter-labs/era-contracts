// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Utils, PrepareL1L2TransactionParams, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS, StateTransitionDeployedAddresses} from "../Utils.sol";
import {L2TransactionRequestDirect, IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {VerifierFflonk} from "contracts/state-transition/verifiers/VerifierFflonk.sol";
import {VerifierPlonk} from "contracts/state-transition/verifiers/VerifierPlonk.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {GatewayUpgrade} from "contracts/upgrades/GatewayUpgrade.sol";
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
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "./SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "./BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {Create2AndTransfer} from "../Create2AndTransfer.sol";

import {FixedForceDeploymentsData, DeployedAddresses, ContractsConfig} from "../DeployUtils.s.sol";
import {DeployL1Script} from "../DeployL1.s.sol";

/// @notice Script used for default upgrade flow
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract EcosystemUpgrade is Script, DeployL1Script {
    using stdToml for string;

    // solhint-disable-next-line gas-struct-packing
    struct UpgradeDeployedAddresses {
        ExpectedL2Addresses expectedL2Addresses;
        address gatewayUpgrade;
        address transitionaryOwner;
        address upgradeTimer;
        address bytecodesSupplier;
        address l2WrappedBaseTokenStore;
    }

    struct ExpectedL2Addresses {
        address expectedRollupL2DAValidator;
        address expectedValidiumL2DAValidator;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
    }

    // solhint-disable-next-line gas-struct-packing
    struct NewConfig {
        uint256 l1ChainId;
        address deployerAddress;
        uint256 eraChainId;
        address ownerAddress;
        // This is the address of the ecosystem admin.
        // Note, that it is not the owner, but rather the address that is responsible
        // for facilitating partially trusted, but not critical tasks.
        address ecosystemAdminAddress;
        bool testnetVerifier;
        uint256 governanceUpgradeTimerInitialDelay;
        NewContractsConfig contracts;
        TokensConfig tokens;
        Gateway gateway;
    }

    // solhint-disable-next-line gas-struct-packing
    struct NewlyGeneratedData {
        bytes fixedForceDeploymentsData;
        bytes diamondCutData;
        bytes upgradeCutData;
    }

    // solhint-disable-next-line gas-struct-packing
    struct NewContractsConfig {
        address bytecodesSupplierAddress;
        bytes32 create2FactorySalt;
        address create2FactoryAddr;
        uint256 validatorTimelockExecutionDelay;
        bytes32 genesisRoot;
        uint256 genesisRollupLeafIndex;
        bytes32 genesisBatchCommitment;
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
        uint256 maxNumberOfChains;
        bytes32 bootloaderHash;
        bytes32 defaultAAHash;
        bytes32 evmEmulatorHash;
        address oldValidatorTimelock;
        address legacyErc20BridgeAddress;
        address bridgehubProxyAddress;
        address l1AssetRouterProxyAddress;
        address stateTransitionManagerAddress;
        address transparentProxyAdmin;
        address eraDiamondProxy;
        uint256 newProtocolVersion;
        uint256 oldProtocolVersion;
        address l1LegacySharedBridge;
        address l1NativeTokenVaultProxy;
        address ctmDeploymentTrackerProxy;
        address messageRootProxy;
        address l1NullifierAddress;
    }

    struct Gateway {
        StateTransitionDeployedAddresses gatewayStateTransition;
        address chainTypeManagerOnGatewayAddress;
        bytes facetCutsData;
        bytes additionalForceDeployments;
        uint256 chainId;
    }

    struct TokensConfig {
        address tokenWethAddress;
    }

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        bool expectedL2AddressesInitialized;
        bool fixedForceDeploymentsDataGenerated;
        bool diamondCutPrepared;
        bool upgradeCutPrepared;
        bool factoryDepsPublished;
        bool ecosystemContractsDeployed;
        string outputPath;
    }

    NewConfig internal newConfig;
    NewlyGeneratedData internal newlyGeneratedData;
    UpgradeDeployedAddresses internal upgradeAddresses;

    uint256[] internal factoryDepsHashes;
    mapping(bytes32 => bool) internal isHashInFactoryDeps;

    EcosystemUpgradeConfig internal upgradeConfig;

    function initialize(string memory newConfigPath, string memory _outputPath) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);

        initializeConfig(newConfigPath);
        initializeOldData();

        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    /// @notice Full default upgrade preparation flow
    function prepareEcosystemUpgrade() public virtual {
        deployNewEcosystemContracts();
        console.log("Ecosystem contracts are deployed!");
        publishBytecodes();
        console.log("Bytecodes published!");
        generateUpgradeData();
        console.log("Upgrade data generated!");
    }

    /// @notice Deploy everything that should be deployed
    function deployNewEcosystemContracts() public virtual {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        // TODO not needed?
        // deployBytecodesSupplier();

        deployBlobVersionedHashRetriever(); // TODO not needed?
        // deployDualVerifier();
        // deployDefaultUpgrade();
        // deployGenesisUpgrade();
        deployGatewayUpgrade(); // TODO not needed?

        initializeExpectedL2Addresses();
        // TODO: can we remove DA redeploy? It isn't behind a proxy
        deployDAValidators();

        // deployBridgehubImplementation();
        // deployCTMDeploymentTrackerImplementation();
        // deployMessageRootContractImplementation();

        // deployL1NullifierImplementation();
        // deployL1AssetRouterImplementation();
        // deployBridgedStandardERC20Implementation();
        // deployBridgedTokenBeacon(); // TODO not needed?
        // deployL1NativeTokenVaultImplementation();
        // deployErc20BridgeImplementation();

        // deployChainTypeManagerContract();

        deployTransitionaryOwner(); // TODO unused?
        deployL2WrappedBaseTokenStore(); // TODO not needed?
        deployGovernanceUpgradeTimer(); // TODO not needed?

        // Additional (optional) newConfiguration after deploy

        allowDAPair(
            addresses.daAddresses.rollupDAManager,
            addresses.daAddresses.l1RollupDAValidator,
            upgradeAddresses.expectedL2Addresses.expectedRollupL2DAValidator
        );

        address[] memory ownershipsToTransfer = new address[](1);
        ownershipsToTransfer[0] = addresses.daAddresses.rollupDAManager;
        transferOwnershipsToGovernance(ownershipsToTransfer);

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    /// @notice Generate data required for the upgrade
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Important, this must come after the initializeExpectedL2Addresses
        generateFixedForceDeploymentsData();
        prepareDiamondCutData({isOnGateway: false});
        generateUpgradeCutData({isOnGateway: false});
        console.log("UpgradeCutGenerated");
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return newConfig.ownerAddress;
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        IZKChain.Facet[] memory facets = IZKChain(newConfig.contracts.eraDiamondProxy).facets();

        // Freezability does not matter when deleting, so we just put false everywhere
        facetCuts = new Diamond.FacetCut[](facets.length);
        for (uint i = 0; i < facets.length; i++) {
            facetCuts[i] = Diamond.FacetCut({
                facet: address(0),
                action: Diamond.Action.Remove,
                isFreezable: false,
                selectors: facets[i].selectors
            });
        }
    }

    /// @notice Get new facet cuts
    function getFacetCuts() internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: addresses.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: addresses.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: addresses.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: addresses.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });
    }

    /// @notice Build L1 -> L2 upgrade tx
    function _composeUpgradeTx(
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments
    ) internal virtual returns (L2CanonicalTransaction memory transaction) {
        // Sanity check
        for (uint256 i; i < forceDeployments.length; i++) {
            require(isHashInFactoryDeps[forceDeployments[i].bytecodeHash], "Bytecode hash not in factory deps");
        }

        bytes memory data = abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (forceDeployments));

        transaction = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR))),
            // TODO: dont use hardcoded values
            gasLimit: 72_000_000,
            gasPerPubdataByteLimit: 800,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: getProtocolUpgradeNonce(),
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: data,
            signature: new bytes(0),
            // All factory deps should've been published before
            factoryDeps: factoryDepsHashes,
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }

    function getNewProtocolVersion() public virtual returns (uint256) {
        return 0x1b00000000; // 27
    }

    function getProtocolUpgradeNonce() public virtual returns (uint256) {
        return (getNewProtocolVersion() >> 32);
    }

    function getOldProtocolDeadline() public virtual returns (uint256) {
        return type(uint256).max;
    }

    function getOldProtocolVersion() public virtual returns (uint256) {
        return 0x1a00000000;
    }

    /// @notice Generate upgrade cut data
    function generateUpgradeCutData(
        bool isOnGateway
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        require(upgradeConfig.factoryDepsPublished, "Factory deps not published");

        Diamond.FacetCut[] memory facetCutsForDeletion = getFacetCutsForDeletion();

        Diamond.FacetCut[] memory facetCuts;
        if (isOnGateway) {
            facetCuts = abi.decode(newConfig.gateway.facetCutsData, (Diamond.FacetCut[]));
        } else {
            facetCuts = getFacetCuts();
        }
        facetCuts = mergeFacets(getFacetCutsForDeletion(), facetCuts);

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: newConfig.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: newConfig.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: newConfig.contracts.recursionCircuitsSetVksHash
        });

        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments();

        // Additional force deployments after Gateway
        IL2ContractDeployer.ForceDeployment[]
            memory additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](4);
        additionalForceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode()),
            newAddress: upgradeAddresses.expectedL2Addresses.l2SharedBridgeLegacyImpl,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[1] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readStandardERC20Bytecode()),
            newAddress: upgradeAddresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[2] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode()),
            newAddress: upgradeAddresses.expectedL2Addresses.expectedRollupL2DAValidator,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[3] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode()),
            newAddress: upgradeAddresses.expectedL2Addresses.expectedValidiumL2DAValidator,
            callConstructor: true,
            value: 0,
            input: ""
        });

        // TODO: do we update *all* fixed force deployments?

        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = SystemContractsProcessing.mergeForceDeployments(
            baseForceDeployments,
            additionalForceDeployments
        );

        address verifierAddress = isOnGateway
            ? newConfig.gateway.gatewayStateTransition.verifier
            : addresses.stateTransition.verifier;
        address defaultUpgradeAddress = isOnGateway
            ? newConfig.gateway.gatewayStateTransition.defaultUpgrade
            : addresses.stateTransition.defaultUpgrade;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeUpgradeTx(forceDeployments),
            bootloaderHash: newConfig.contracts.bootloaderHash,
            defaultAccountHash: newConfig.contracts.defaultAAHash,
            evmEmulatorHash: newConfig.contracts.evmEmulatorHash,
            verifier: verifierAddress,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: defaultUpgradeAddress,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });

        if (!isOnGateway) {
            newlyGeneratedData.upgradeCutData = abi.encode(upgradeCutData);
            upgradeConfig.upgradeCutPrepared = true;
        }
    }

    function getEcosystemAdmin() external virtual returns (address) {
        return newConfig.ecosystemAdminAddress;
    }

    function initializeConfig(string memory newConfigPath) internal virtual override {
        string memory toml = vm.readFile(newConfigPath);

        newConfig.l1ChainId = block.chainid;
        newConfig.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        newConfig.eraChainId = toml.readUint("$.era_chain_id");
        newConfig.testnetVerifier = toml.readBool("$.testnet_verifier");

        newConfig.contracts.maxNumberOfChains = toml.readUint("$.contracts.max_number_of_chains");
        newConfig.contracts.create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            newConfig.contracts.create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        newConfig.contracts.bytecodesSupplierAddress = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");
        newConfig.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        newConfig.contracts.genesisRoot = toml.readBytes32("$.contracts.genesis_root");
        newConfig.contracts.genesisRollupLeafIndex = toml.readUint("$.contracts.genesis_rollup_leaf_index");
        newConfig.contracts.genesisBatchCommitment = toml.readBytes32("$.contracts.genesis_batch_commitment");
        newConfig.contracts.recursionNodeLevelVkHash = toml.readBytes32("$.contracts.recursion_node_level_vk_hash");
        newConfig.contracts.recursionLeafLevelVkHash = toml.readBytes32("$.contracts.recursion_leaf_level_vk_hash");
        newConfig.contracts.recursionCircuitsSetVksHash = toml.readBytes32("$.contracts.recursion_circuits_set_vks_hash");
        newConfig.contracts.priorityTxMaxGasLimit = toml.readUint("$.contracts.priority_tx_max_gas_limit");
        newConfig.contracts.diamondInitPubdataPricingMode = PubdataPricingMode(
            toml.readUint("$.contracts.diamond_init_pubdata_pricing_mode")
        );
        newConfig.contracts.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.contracts.diamond_init_batch_overhead_l1_gas"
        );
        newConfig.contracts.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_pubdata_per_batch"
        );
        newConfig.contracts.diamondInitMaxL2GasPerBatch = toml.readUint("$.contracts.diamond_init_max_l2_gas_per_batch");
        newConfig.contracts.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.contracts.diamond_init_priority_tx_max_pubdata"
        );
        newConfig.contracts.diamondInitMinimalL2GasPrice = toml.readUint("$.contracts.diamond_init_minimal_l2_gas_price");
        newConfig.contracts.defaultAAHash = toml.readBytes32("$.contracts.default_aa_hash");
        newConfig.contracts.bootloaderHash = toml.readBytes32("$.contracts.bootloader_hash");
        newConfig.contracts.evmEmulatorHash = toml.readBytes32("$.contracts.evm_emulator_hash");

        newConfig.contracts.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");

        newConfig.ownerAddress = Bridgehub(newConfig.contracts.bridgehubProxyAddress).owner();
        newConfig.contracts.stateTransitionManagerAddress = IBridgehub(newConfig.contracts.bridgehubProxyAddress)
            .chainTypeManager(newConfig.eraChainId);
        newConfig.contracts.l1AssetRouterProxyAddress = Bridgehub(newConfig.contracts.bridgehubProxyAddress).sharedBridge(); // TODO old?

        newConfig.contracts.l1NativeTokenVaultProxy = address(
            L1AssetRouter(newConfig.contracts.l1AssetRouterProxyAddress).nativeTokenVault()
        );
        newConfig.contracts.l1NullifierAddress = address(
            L1AssetRouter(newConfig.contracts.l1AssetRouterProxyAddress).L1_NULLIFIER()
        );

        newConfig.contracts.ctmDeploymentTrackerProxy = address(
            Bridgehub(newConfig.contracts.bridgehubProxyAddress).l1CtmDeployer()
        );
        newConfig.contracts.messageRootProxy = address(Bridgehub(newConfig.contracts.bridgehubProxyAddress).messageRoot());

        newConfig.contracts.eraDiamondProxy = ChainTypeManager(newConfig.contracts.stateTransitionManagerAddress)
            .getHyperchain(newConfig.eraChainId);
        newConfig.contracts.legacyErc20BridgeAddress = address(
            L1AssetRouter(newConfig.contracts.l1AssetRouterProxyAddress).legacyBridge()
        );
        newConfig.contracts.oldValidatorTimelock = ChainTypeManager(newConfig.contracts.stateTransitionManagerAddress)
            .validatorTimelock();

        newConfig.contracts.transparentProxyAdmin = toml.readAddress("$.contracts.transparent_proxy_admin");

        newConfig.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
        newConfig.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");

        newConfig.ecosystemAdminAddress = Bridgehub(newConfig.contracts.bridgehubProxyAddress).admin();

        newConfig.gateway.facetCutsData = abi.encode(new Diamond.DiamondCutData[](0)); // TODO
        newConfig.gateway.additionalForceDeployments = abi.encode(new IL2ContractDeployer.ForceDeployment[](0)); // TODO

        newConfig.gateway.gatewayStateTransition.chainTypeManagerImplementation = toml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_implementation_addr"
        );
        newConfig.gateway.gatewayStateTransition.verifier = toml.readAddress(
            "$.gateway.gateway_state_transition.verifier_addr"
        );
        newConfig.gateway.gatewayStateTransition.adminFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.admin_facet_addr"
        );
        newConfig.gateway.gatewayStateTransition.mailboxFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.mailbox_facet_addr"
        );
        newConfig.gateway.gatewayStateTransition.executorFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.executor_facet_addr"
        );
        newConfig.gateway.gatewayStateTransition.gettersFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.getters_facet_addr"
        );
        newConfig.gateway.gatewayStateTransition.diamondInit = toml.readAddress(
            "$.gateway.gateway_state_transition.diamond_init_addr"
        );
        newConfig.gateway.gatewayStateTransition.genesisUpgrade = toml.readAddress(
            "$.gateway.gateway_state_transition.genesis_upgrade_addr"
        );
        newConfig.gateway.gatewayStateTransition.defaultUpgrade = toml.readAddress(
            "$.gateway.gateway_state_transition.default_upgrade_addr"
        );
        newConfig.gateway.gatewayStateTransition.validatorTimelock = toml.readAddress(
            "$.gateway.gateway_state_transition.validator_timelock_addr"
        );

        newConfig.gateway.chainTypeManagerOnGatewayAddress = toml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_proxy_addr"
        );
    }

    function initializeOldData() internal virtual {
        newConfig.contracts.newProtocolVersion = getNewProtocolVersion();
        newConfig.contracts.oldProtocolVersion = getOldProtocolVersion();

        uint256 ctmProtocolVersion = ChainTypeManager(newConfig.contracts.stateTransitionManagerAddress).protocolVersion();
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );

        newConfig.contracts.oldValidatorTimelock = ChainTypeManager(newConfig.contracts.stateTransitionManagerAddress)
            .validatorTimelock();

        // In the future this value will be populated with the new shared bridge, but since the version on the CTM is the old one, the old bridge is stored here as well.
        newConfig.contracts.l1LegacySharedBridge = Bridgehub(newConfig.contracts.bridgehubProxyAddress).sharedBridge();
    }

    function generateFixedForceDeploymentsData() internal virtual {
        require(upgradeConfig.expectedL2AddressesInitialized, "Expected L2 addresses not initialized");
        FixedForceDeploymentsData memory forceDeploymentsData = prepareFixedForceDeploymentsData();

        newlyGeneratedData.fixedForceDeploymentsData = abi.encode(forceDeploymentsData);
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    function initializeExpectedL2Addresses() internal virtual {
        address aliasedGovernance = AddressAliasHelper.applyL1ToL2Alias(newConfig.ownerAddress);

        upgradeAddresses.expectedL2Addresses = ExpectedL2Addresses({
            expectedRollupL2DAValidator: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode()),
                hex""
            ),
            expectedValidiumL2DAValidator: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode()),
                hex""
            ),
            l2SharedBridgeLegacyImpl: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode()),
                hex""
            ),
            l2BridgedStandardERC20Impl: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readStandardERC20Bytecode()),
                hex""
            )
        });

        upgradeConfig.expectedL2AddressesInitialized = true;
    }

    function getGovernanceUpgradeInitialDelay() external view virtual returns (uint256) {
        return newConfig.governanceUpgradeTimerInitialDelay;
    }

    function getFullListOfFactoryDependencies() internal virtual returns (bytes[] memory factoryDeps) {
        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies();

        bytes[] memory additionalDependencies = new bytes[](4); // Deps after Gateway upgrade
        additionalDependencies[0] = L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode();
        additionalDependencies[1] = L2ContractsBytecodesLib.readStandardERC20Bytecode();
        additionalDependencies[2] = L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode();
        additionalDependencies[3] = L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode();

        factoryDeps = SystemContractsProcessing.mergeBytesArrays(basicDependencies, additionalDependencies);
        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }

    function prepareDiamondCutData(bool isOnGateway) internal virtual returns (Diamond.DiamondCutData memory) {
        Diamond.FacetCut[] memory facetCuts;

        if (isOnGateway) {
            abi.decode(newConfig.gateway.facetCutsData, (Diamond.FacetCut[]));
        } else {
            facetCuts = getFacetCuts();
        }

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: newConfig.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: newConfig.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: newConfig.contracts.recursionCircuitsSetVksHash
        });

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: newConfig.contracts.diamondInitPubdataPricingMode,
            batchOverheadL1Gas: uint32(newConfig.contracts.diamondInitBatchOverheadL1Gas),
            maxPubdataPerBatch: uint32(newConfig.contracts.diamondInitMaxPubdataPerBatch),
            maxL2GasPerBatch: uint32(newConfig.contracts.diamondInitMaxL2GasPerBatch),
            priorityTxMaxPubdata: uint32(newConfig.contracts.diamondInitPriorityTxMaxPubdata),
            minimalL2GasPrice: uint64(newConfig.contracts.diamondInitMinimalL2GasPrice)
        });

        address verifierAddress = isOnGateway
            ? newConfig.gateway.gatewayStateTransition.verifier
            : addresses.stateTransition.verifier;
        address blobVersionedHashRetrieverAddress = isOnGateway ? ADDRESS_ONE : addresses.blobVersionedHashRetriever; // Not needed on Gateway
        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(verifierAddress),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: newConfig.contracts.bootloaderHash,
            l2DefaultAccountBytecodeHash: newConfig.contracts.defaultAAHash,
            l2EvmEmulatorBytecodeHash: newConfig.contracts.evmEmulatorHash,
            priorityTxMaxGasLimit: newConfig.contracts.priorityTxMaxGasLimit,
            feeParams: feeParams,
            blobVersionedHashRetriever: blobVersionedHashRetrieverAddress
        });

        address diamondInitAddress = isOnGateway
            ? newConfig.gateway.gatewayStateTransition.diamondInit
            : addresses.stateTransition.diamondInit;
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: diamondInitAddress,
            initCalldata: abi.encode(initializeData)
        });

        if (!isOnGateway) {
            newlyGeneratedData.diamondCutData = abi.encode(diamondCut);
            upgradeConfig.diamondCutPrepared = true;
        }

        return (diamondCut);
    }

    function prepareNewChainCreationParams(
        bool isOnGateway
    ) internal virtual returns (ChainCreationParams memory chainCreationParams) {
        require(upgradeConfig.fixedForceDeploymentsDataGenerated, "Force deployment data not generated");

        Diamond.DiamondCutData memory diamondCut;
        address genesisUpgradeAddress;

        if (!isOnGateway) {
            require(upgradeConfig.diamondCutPrepared, "Diamond cut not prepared");
            diamondCut = abi.decode(newlyGeneratedData.diamondCutData, (Diamond.DiamondCutData));
            genesisUpgradeAddress = addresses.stateTransition.genesisUpgrade;
        } else {
            diamondCut = prepareDiamondCutData({isOnGateway: true});
            genesisUpgradeAddress = newConfig.gateway.gatewayStateTransition.genesisUpgrade;
        }

        chainCreationParams = ChainCreationParams({
            genesisUpgrade: genesisUpgradeAddress,
            genesisBatchHash: newConfig.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(newConfig.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: newConfig.contracts.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: newlyGeneratedData.fixedForceDeploymentsData
        });
    }

    function prepareFixedForceDeploymentsData() public view virtual returns (FixedForceDeploymentsData memory data) {
        require(newConfig.ownerAddress != address(0), "owner not set");

        data = FixedForceDeploymentsData({
            l1ChainId: newConfig.l1ChainId, // TODO: what should be used if it is on Gateway?
            eraChainId: newConfig.eraChainId,
            l1AssetRouter: newConfig.contracts.l1AssetRouterProxyAddress,
            l2TokenProxyBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readBeaconProxyBytecode()
            ),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(newConfig.ownerAddress),
            maxNumberOfZKChains: newConfig.contracts.maxNumberOfChains,
            bridgehubBytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readBridgehubBytecode()),
            l2AssetRouterBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readL2AssetRouterBytecode()
            ),
            l2NtvBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readL2NativeTokenVaultBytecode()
            ),
            messageRootBytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readMessageRootBytecode()),
            l2SharedBridgeLegacyImpl: upgradeAddresses.expectedL2Addresses.l2SharedBridgeLegacyImpl,
            l2BridgedStandardERC20Impl: upgradeAddresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            dangerousTestOnlyForcedBeacon: address(0)
        });
    }

    function saveOutput(string memory outputPath) internal virtual override {
        vm.serializeAddress("bridgehub", "bridgehub_implementation_addr", addresses.bridgehub.bridgehubImplementation);
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            addresses.bridgehub.ctmDeploymentTrackerImplementation
        );
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            addresses.bridgehub.messageRootImplementation
        );

        // TODO(EVM-744): this has to be renamed to chain type manager
        vm.serializeAddress(
            "state_transition",
            "state_transition_implementation_addr",
            addresses.stateTransition.chainTypeManagerImplementation
        );
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_implementation_addr",
            addresses.stateTransition.chainTypeManagerImplementation
        );
        vm.serializeAddress("state_transition", "verifier_addr", addresses.stateTransition.verifier);
        vm.serializeAddress("state_transition", "admin_facet_addr", addresses.stateTransition.adminFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", addresses.stateTransition.mailboxFacet);
        vm.serializeAddress("state_transition", "executor_facet_addr", addresses.stateTransition.executorFacet);
        vm.serializeAddress("state_transition", "getters_facet_addr", addresses.stateTransition.gettersFacet);
        vm.serializeAddress("state_transition", "diamond_init_addr", addresses.stateTransition.diamondInit);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", addresses.stateTransition.genesisUpgrade);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            addresses.stateTransition.defaultUpgrade
        );

        vm.serializeAddress("bridges", "erc20_bridge_implementation_addr", addresses.bridges.erc20BridgeImplementation);
        vm.serializeAddress("bridges", "l1_nullifier_implementation_addr", addresses.bridges.l1NullifierImplementation);
        vm.serializeAddress(
            "bridges",
            "l1_asset_router_implementation_addr",
            addresses.bridges.l1AssetRouterImplementation
        );
        // TODO: legacy name
        vm.serializeAddress(
            "bridges",
            "shared_bridge_implementation_addr",
            addresses.bridges.l1AssetRouterImplementation
        );
        vm.serializeAddress(
            "bridges",
            "bridged_standard_erc20_impl",
            addresses.bridges.bridgedStandardERC20Implementation
        );

        string memory bridges = vm.serializeAddress(
            "bridges",
            "bridged_token_beacon",
            addresses.bridges.bridgedTokenBeacon
        );

        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_max_l2_gas_per_batch",
            newConfig.contracts.diamondInitMaxL2GasPerBatch
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_batch_overhead_l1_gas",
            newConfig.contracts.diamondInitBatchOverheadL1Gas
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_max_pubdata_per_batch",
            newConfig.contracts.diamondInitMaxPubdataPerBatch
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_minimal_l2_gas_price",
            newConfig.contracts.diamondInitMinimalL2GasPrice
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_priority_tx_max_pubdata",
            newConfig.contracts.diamondInitPriorityTxMaxPubdata
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_pubdata_pricing_mode",
            uint256(newConfig.contracts.diamondInitPubdataPricingMode)
        );
        vm.serializeUint("contracts_newConfig", "priority_tx_max_gas_limit", newConfig.contracts.priorityTxMaxGasLimit);
        vm.serializeBytes32(
            "contracts_newConfig",
            "recursion_circuits_set_vks_hash",
            newConfig.contracts.recursionCircuitsSetVksHash
        );
        vm.serializeBytes32(
            "contracts_newConfig",
            "recursion_leaf_level_vk_hash",
            newConfig.contracts.recursionLeafLevelVkHash
        );
        vm.serializeBytes32(
            "contracts_newConfig",
            "recursion_node_level_vk_hash",
            newConfig.contracts.recursionNodeLevelVkHash
        );

        vm.serializeAddress(
            "contracts_newConfig",
            "expected_rollup_l2_da_validator",
            upgradeAddresses.expectedL2Addresses.expectedRollupL2DAValidator
        );
        vm.serializeAddress(
            "contracts_newConfig",
            "expected_validium_l2_da_validator",
            upgradeAddresses.expectedL2Addresses.expectedValidiumL2DAValidator
        );
        vm.serializeBytes("contracts_newConfig", "diamond_cut_data", newlyGeneratedData.diamondCutData);

        vm.serializeBytes("contracts_newConfig", "force_deployments_data", newlyGeneratedData.fixedForceDeploymentsData);

        vm.serializeUint("contracts_newConfig", "new_protocol_version", newConfig.contracts.newProtocolVersion);

        vm.serializeUint("contracts_newConfig", "old_protocol_version", newConfig.contracts.oldProtocolVersion);

        vm.serializeAddress("contracts_newConfig", "old_validator_timelock", newConfig.contracts.oldValidatorTimelock);

        string memory contractsConfig = vm.serializeAddress(
            "contracts_newConfig",
            "l1_legacy_shared_bridge",
            newConfig.contracts.l1LegacySharedBridge
        );

        vm.serializeAddress("deployed_addresses", "validator_timelock_addr", addresses.validatorTimelock);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);
        vm.serializeString("deployed_addresses", "state_transition", stateTransition);

        vm.serializeAddress(
            "deployed_addresses",
            "rollup_l1_da_validator_addr",
            addresses.daAddresses.l1RollupDAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "validium_l1_da_validator_addr",
            addresses.daAddresses.noDAValidiumL1DAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "l2_wrapped_base_token_store_addr",
            upgradeAddresses.l2WrappedBaseTokenStore
        );
        vm.serializeAddress("deployed_addresses", "l1_gateway_upgrade", upgradeAddresses.gatewayUpgrade);
        vm.serializeAddress("deployed_addresses", "l1_transitionary_owner", upgradeAddresses.transitionaryOwner);
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            upgradeAddresses.upgradeTimer
        );

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", newConfig.contracts.create2FactorySalt);
        vm.serializeUint("root", "l1_chain_id", newConfig.l1ChainId);
        vm.serializeUint("root", "era_chain_id", newConfig.eraChainId);
        vm.serializeAddress("root", "deployer_addr", newConfig.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_newConfig", contractsConfig);

        vm.serializeBytes("root", "governance_calls", new bytes(0)); // Will be populated later

        vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        string memory toml = vm.serializeAddress("root", "owner_address", newConfig.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    function publishBytecodes() public virtual {
        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        uint256[] memory factoryDeps = new uint256[](allDeps.length);
        require(factoryDeps.length <= 64, "Too many deps");

        BytecodePublisher.publishBytecodesInBatches(
            BytecodesSupplier(newConfig.contracts.bytecodesSupplierAddress),
            allDeps
        );

        for (uint256 i = 0; i < allDeps.length; i++) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(allDeps[i]);
            factoryDeps[i] = uint256(bytecodeHash);
            isHashInFactoryDeps[bytecodeHash] = true;
        }

        // Double check for consistency:
        require(bytes32(factoryDeps[0]) == newConfig.contracts.bootloaderHash, "bootloader hash factory dep mismatch");
        require(bytes32(factoryDeps[1]) == newConfig.contracts.defaultAAHash, "default aa hash factory dep mismatch");
        require(bytes32(factoryDeps[2]) == newConfig.contracts.evmEmulatorHash, "EVM emulator hash factory dep mismatch");

        factoryDepsHashes = factoryDeps;

        upgradeConfig.factoryDepsPublished = true;
    }

    // Permissioned actions

    function _transferOwnershipToGovernance(address target) internal virtual {
        if (Ownable2StepUpgradeable(target).owner() != newConfig.ownerAddress) {
            Ownable2StepUpgradeable(target).transferOwnership(upgradeAddresses.transitionaryOwner);
            TransitionaryOwner(upgradeAddresses.transitionaryOwner).claimOwnershipAndGiveToGovernance(target);
        }
    }

    function _transferOwnershipToEcosystemAdmin(address target) internal virtual {
        if (Ownable2StepUpgradeable(target).owner() != newConfig.ecosystemAdminAddress) {
            // Is agile enough to accept ownership quickly
            Ownable2StepUpgradeable(target).transferOwnership(newConfig.ecosystemAdminAddress);
        }
    }

    function transferOwnershipsToGovernance(address[] memory addressesToUpdate) public virtual {
        vm.startBroadcast(msg.sender);

        // Note, that it will take some time for the governance to sign the "acceptOwnership" transaction,
        // in order to avoid any possibility of the front-run, we will temporarily give the ownership to the
        // contract that can only transfer ownership to the governance.
        for (uint256 i; i < addressesToUpdate.length; i++) {
            _transferOwnershipToGovernance(addressesToUpdate[i]);
        }

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function allowDAPair(
        address rollupDAManager,
        address l1RollupDAValidator,
        address expectedRollupL2DAValidator
    ) public virtual {
        if (
            !RollupDAManager(rollupDAManager).isPairAllowed(address(l1RollupDAValidator), expectedRollupL2DAValidator)
        ) {
            vm.broadcast(msg.sender);
            RollupDAManager(rollupDAManager).updateDAPair(
                address(l1RollupDAValidator),
                expectedRollupL2DAValidator,
                true
            );
        }
        console.log("DA pair set");
    }

    /////////////////////////// Deployment of contracts ////////////////////////////

    // function deployBytecodesSupplier() internal virtual {
    //     upgradeAddresses.bytecodesSupplier = deployViaCreate2AndNotify(
    //         type(BytecodesSupplier).creationCode,
    //         abi.encode(),
    //         "BytecodesSupplier"
    //     );
    // }

    // function deployDualVerifier() internal virtual {
    //     address verifierFflonk = deployVerifierFflonk();
    //     address verifierPlonk = deployVerifierPlonk();
    //     bytes memory code;
    //     string memory contractName;
    //     if (newConfig.testnetVerifier) {
    //         code = type(TestnetVerifier).creationCode;
    //         contractName = "TestnetVerifier";
    //     } else {
    //         code = type(DualVerifier).creationCode;
    //         contractName = "DualVerifier";
    //     }

    //     addresses.stateTransition.verifier = deployViaCreate2AndNotify(
    //         code,
    //         abi.encode(verifierFflonk, verifierPlonk),
    //         contractName
    //     );
    // }

    // function deployVerifierFflonk() internal virtual returns (address contractAddress) {
    //     contractAddress = deployViaCreate2AndNotify(type(VerifierFflonk).creationCode, abi.encode(), "VerifierFflonk");
    // }

    // function deployVerifierPlonk() internal virtual returns (address contractAddress) {
    //     contractAddress = deployViaCreate2AndNotify(type(VerifierPlonk).creationCode, abi.encode(), "VerifierPlonk");
    // }
    // function deployDefaultUpgrade() internal virtual {
    //     addresses.stateTransition.defaultUpgrade = deployViaCreate2AndNotify(
    //         type(DefaultUpgrade).creationCode,
    //         abi.encode(),
    //         "DefaultUpgrade"
    //     );
    // }

    // function deployGenesisUpgrade() internal virtual {
    //     addresses.stateTransition.genesisUpgrade = deployViaCreate2AndNotify(
    //         type(L1GenesisUpgrade).creationCode,
    //         abi.encode(),
    //         "L1GenesisUpgrade"
    //     );
    // }

    function deployGatewayUpgrade() internal virtual {
        upgradeAddresses.gatewayUpgrade = deployViaCreate2AndNotify(
            type(GatewayUpgrade).creationCode,
            abi.encode(),
            "GatewayUpgrade"
        );
    }

    // function deployChainTypeManagerImplementation() internal virtual {
    //     addresses.stateTransition.chainTypeManagerImplementation = deployViaCreate2AndNotify(
    //         type(ChainTypeManager).creationCode,
    //         abi.encode(newConfig.contracts.bridgehubProxyAddress),
    //         "ChainTypeManager",
    //         "ChainTypeManagerImplementation"
    //     );
    // }
    // function deployBridgedTokenBeacon() internal virtual {
    //     addresses.bridges.bridgedTokenBeacon = deployViaCreate2AndNotify(
    //         type(UpgradeableBeacon).creationCode,
    //         abi.encode(addresses.bridges.bridgedStandardERC20Implementation),
    //         "UpgradeableBeacon"
    //     );
    // }

    // function deployL1NativeTokenVaultImplementation() internal virtual {
    //     addresses.vaults.l1NativeTokenVaultImplementation = deployViaCreate2AndNotify(
    //         type(L1NativeTokenVault).creationCode,
    //         // solhint-disable-next-line func-named-parameters
    //         abi.encode(
    //             newConfig.tokens.tokenWethAddress,
    //             newConfig.contracts.l1AssetRouterProxyAddress,
    //             newConfig.contracts.l1NullifierAddress
    //         ),
    //         "L1NativeTokenVault",
    //         "L1NativeTokenVaultImplementation"
    //     );
    // }

    function deployGovernanceUpgradeTimer() internal virtual {
        uint256 initialDelay = newConfig.governanceUpgradeTimerInitialDelay;

        uint256 maxAdditionalDelay = 2 weeks;

        // It may make sense to have a separate admin there, but
        // using the same as bridgehub is just as fine.
        address bridgehubAdmin = Bridgehub(newConfig.contracts.bridgehubProxyAddress).admin();

        upgradeAddresses.upgradeTimer = deployViaCreate2AndNotify(
            type(GovernanceUpgradeTimer).creationCode,
            abi.encode(initialDelay, maxAdditionalDelay, newConfig.ownerAddress, newConfig.ecosystemAdminAddress),
            "GovernanceUpgradeTimer"
        );
    }

    function deployL2WrappedBaseTokenStore() internal virtual {
        upgradeAddresses.l2WrappedBaseTokenStore = deployViaCreate2AndNotify(
            type(L2WrappedBaseTokenStore).creationCode,
            // We set a temoprary admin there. This is needed for easier/quicker setting of
            // wrapped base tokens. The ownership MUST be transferred to a trusted admin before the
            // decentralized upgrade voting starts.
            abi.encode(newConfig.ownerAddress, msg.sender),
            "L2WrappedBaseTokenStore"
        );
    }

    function deployTransitionaryOwner() internal virtual {
        upgradeAddresses.transitionaryOwner = deployViaCreate2AndNotify(
            type(TransitionaryOwner).creationCode,
            abi.encode(newConfig.ownerAddress),
            "TransitionaryOwner"
        );
    }

    ////////////////////////////// Preparing calls /////////////////////////////////

    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        // Default upgrade is done it 2 stages:
        // 1. Pause migration to/from Gateway
        // 2. Perform upgrade
        stage1Calls = prepareStage1GovernanceCalls();
        vm.serializeBytes("governance_calls", "governance_stage1_calls", abi.encode(stage1Calls));

        stage2Calls = prepareStage2GovernanceCalls();

        string memory governanceCallsSerialized = vm.serializeBytes(
            "governance_calls",
            "governance_stage2_calls",
            abi.encode(stage2Calls)
        );

        vm.writeToml(governanceCallsSerialized, upgradeConfig.outputPath, ".governance_calls");
    }

    /// @notice The first step of upgrade. By default it just stops gateway migrations
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](2);
        allCalls[0] = preparePauseGatewayMigrationsCall();
        allCalls[1] = prepareGatewaySpecificStage1GovernanceCalls();

        calls = mergeCallsArray(allCalls);
    }

    function prepareGatewaySpecificStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](2);

        uint256 l2GasLimit = 2000000; // TODO constant or newConfig
        uint256 l1GasPrice = 100; // TODO constant or newConfig

        uint256 tokensRequired;
        (allCalls[1], tokensRequired) = preparePauseMigrationCallForGateway(l2GasLimit, l1GasPrice);

        // Approve required amount of base token
        allCalls[0] = prepareApproveGatewayBaseTokenCall(newConfig.contracts.l1AssetRouterProxyAddress, tokensRequired);

        calls = mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it is actual upgrade
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](6);
        allCalls[0] = prepareUpgradeProxiesCalls();
        allCalls[1] = prepareNewChainCreationParamsCall();
        allCalls[2] = provideSetNewVersionUpgradeCall();
        allCalls[3] = prepareUnpauseGatewayMigrationsCall();
        allCalls[4] = prepareContractsConfigurationCalls();
        allCalls[5] = prepareGatewaySpecificStage2GovernanceCalls();
        // TODO not needed?
        //allCalls[5] = prepareGovernanceUpgradeTimerCheckCall();

        calls = mergeCallsArray(allCalls);
    }

    function prepareGatewaySpecificStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](4);

        uint256 l2GasLimit = 2000000; // TODO constant or newConfig
        uint256 l1GasPrice = 100; // TODO constant or newConfig

        uint256 tokensRequired;
        uint256 tokensForCall;
        (allCalls[1], tokensForCall) = provideSetNewVersionUpgradeCallForGateway(l2GasLimit, l1GasPrice);
        tokensRequired += tokensForCall;

        (allCalls[2], tokensForCall) = prepareNewChainCreationParamsCallForGateway(l2GasLimit, l1GasPrice);
        tokensRequired += tokensForCall;

        (allCalls[3], tokensForCall) = prepareUnpauseMigrationCallForGateway(l2GasLimit, l1GasPrice);
        tokensRequired += tokensForCall;

        // Approve required amount of base token
        allCalls[0] = prepareApproveGatewayBaseTokenCall(newConfig.contracts.l1AssetRouterProxyAddress, tokensRequired);

        calls = mergeCallsArray(allCalls);
    }

    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {
        require(
            newConfig.contracts.stateTransitionManagerAddress != address(0),
            "stateTransitionManagerAddress is zero in newConfig"
        );

        // Just retrieved it from the contract
        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCut = abi.decode(newlyGeneratedData.upgradeCutData, (Diamond.DiamondCutData));
        Call memory ctmCall = Call({
            target: newConfig.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(
                ChainTypeManager.setNewVersionUpgrade,
                (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
            ),
            value: 0
        });

        // The call that will start the timer till the end of the upgrade.
        // TODO
        Call memory timerCall = Call({
            target: upgradeAddresses.upgradeTimer,
            data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()),
            value: 0
        });

        calls = new Call[](2);
        calls[0] = ctmCall;
        calls[1] = timerCall;
    }

    function provideSetNewVersionUpgradeCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls, uint256 requiredTokens) {
        require(
            newConfig.gateway.chainTypeManagerOnGatewayAddress != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCut = generateUpgradeCutData({isOnGateway: true});

        bytes memory l2Calldata = abi.encodeCall(
            ChainTypeManager.setNewVersionUpgrade,
            (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
        );

        // TODO: approve base token
        calls = new Call[](1);
        (calls[0], requiredTokens) = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            newConfig.gateway.chainTypeManagerOnGatewayAddress
        );
    }

    function preparePauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(newConfig.contracts.bridgehubProxyAddress != address(0), "bridgehubProxyAddress is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: newConfig.contracts.bridgehubProxyAddress,
            value: 0,
            data: abi.encodeCall(IBridgehub.pauseMigration, ())
        });
    }

    function preparePauseMigrationCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls, uint256 requiredTokens) {
        bytes memory l2Calldata = abi.encodeCall(IBridgehub.pauseMigration, ());

        // TODO: approve base token
        calls = new Call[](1);
        (calls[0], requiredTokens) = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            newConfig.contracts.bridgehubProxyAddress
        );
    }

    function prepareUnpauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(newConfig.contracts.bridgehubProxyAddress != address(0), "bridgehubProxyAddress is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: newConfig.contracts.bridgehubProxyAddress,
            value: 0,
            data: abi.encodeCall(IBridgehub.unpauseMigration, ())
        });
    }

    function prepareUnpauseMigrationCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls, uint256 requiredTokens) {
        bytes memory l2Calldata = abi.encodeCall(IBridgehub.unpauseMigration, ());

        // TODO: approve base token
        calls = new Call[](1);
        (calls[0], requiredTokens) = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            newConfig.contracts.bridgehubProxyAddress
        );
    }

    function prepareAcceptOwnershipCalls(
        address[] memory addressesToAccept
    ) public virtual returns (Call[] memory calls) {
        console.log("Providing accept ownership calls");
        calls = new Call[](addressesToAccept.length);

        for (uint256 i; i < addressesToAccept.length; i++) {
            calls[i] = Call({
                target: addressesToAccept[i],
                data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
                value: 0
            });
        }
    }

    function prepareNewChainCreationParamsCall() public virtual returns (Call[] memory calls) {
        require(
            newConfig.contracts.stateTransitionManagerAddress != address(0),
            "stateTransitionManagerAddress is zero in newConfig"
        );
        calls = new Call[](1);

        calls[0] = Call({
            target: newConfig.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(
                ChainTypeManager.setChainCreationParams,
                (prepareNewChainCreationParams({isOnGateway: false}))
            ),
            value: 0
        });
    }

    function prepareNewChainCreationParamsCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls, uint256 requiredTokens) {
        require(
            newConfig.gateway.chainTypeManagerOnGatewayAddress != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        bytes memory l2Calldata = abi.encodeCall(
            ChainTypeManager.setChainCreationParams,
            (prepareNewChainCreationParams({isOnGateway: true}))
        );

        // TODO: approve base token
        calls = new Call[](1);
        (calls[0], requiredTokens) = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            newConfig.gateway.chainTypeManagerOnGatewayAddress
        );
    }

    function _prepareL1ToGatewayCall(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        uint256 l1GasPrice,
        address dstAddress
    ) internal returns (Call memory call, uint256 requiredTokens) {
        require(newConfig.gateway.chainId != 0, "Chain id of gateway is zero in newConfig");

        require(newConfig.contracts.bridgehubProxyAddress != address(0), "bridgehubProxyAddress is zero in newConfig");
        require(
            newConfig.contracts.l1AssetRouterProxyAddress != address(0),
            "l1AssetRouterProxyAddress is zero in newConfig"
        );

        L2TransactionRequestDirect memory l2TransactionRequestDirect;
        (l2TransactionRequestDirect, requiredTokens) = Utils.prepareL1L2Transaction(
            PrepareL1L2TransactionParams({
                l1GasPrice: l1GasPrice,
                l2Calldata: l2Calldata,
                l2GasLimit: l2GasLimit,
                l2Value: 0,
                factoryDeps: new bytes[](0),
                dstAddress: dstAddress,
                chainId: newConfig.gateway.chainId,
                bridgehubAddress: newConfig.contracts.bridgehubProxyAddress,
                l1SharedBridgeProxy: newConfig.contracts.l1AssetRouterProxyAddress
            })
        );

        call = Call({
            target: newConfig.contracts.bridgehubProxyAddress,
            data: abi.encodeCall(IBridgehub.requestL2TransactionDirect, (l2TransactionRequestDirect)),
            value: 0
        });
    }

    function prepareApproveGatewayBaseTokenCall(
        address spender,
        uint256 amount
    ) public virtual returns (Call[] memory calls) {
        address token = IBridgehub(newConfig.contracts.bridgehubProxyAddress).baseToken(newConfig.gateway.chainId);
        require(token != address(0), "Base token for Gateway is zero");

        calls = new Call[](1);

        calls[0] = Call({target: token, data: abi.encodeCall(IERC20.approve, (spender, amount)), value: 0});
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public virtual returns (Call[] memory calls) {
        // TODO
        calls = new Call[](8);

        calls[0] = _buildCallProxyUpgrade(
            newConfig.contracts.stateTransitionManagerAddress,
            addresses.stateTransition.chainTypeManagerImplementation
        );

        calls[1] = _buildCallProxyUpgrade(
            newConfig.contracts.bridgehubProxyAddress,
            addresses.bridgehub.bridgehubImplementation
        );

        // Note, that we do not need to run the initializer
        calls[2] = _buildCallProxyUpgrade(
            newConfig.contracts.l1NullifierAddress,
            addresses.bridges.l1NullifierImplementation
        );

        calls[3] = _buildCallProxyUpgrade(
            newConfig.contracts.legacyErc20BridgeAddress,
            addresses.bridges.erc20BridgeImplementation
        );

        calls[4] = _buildCallProxyUpgrade(
            newConfig.contracts.l1AssetRouterProxyAddress,
            addresses.bridges.l1AssetRouterImplementation
        );

        calls[5] = _buildCallProxyUpgrade(
            newConfig.contracts.l1NativeTokenVaultProxy,
            addresses.vaults.l1NativeTokenVaultImplementation
        );

        calls[6] = _buildCallProxyUpgrade(
            newConfig.contracts.ctmDeploymentTrackerProxy,
            addresses.bridgehub.ctmDeploymentTrackerImplementation
        );

        calls[7] = _buildCallProxyUpgrade(
            newConfig.contracts.messageRootProxy,
            addresses.bridgehub.messageRootImplementation
        );
    }

    /// @notice Additional calls to newConfigure contracts
    function prepareContractsConfigurationCalls() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        // TODO not needed?
        calls[0] = Call({
            target: newConfig.contracts.stateTransitionManagerAddress,
            // Making the old protocol version no longer invalid
            data: abi.encodeCall(ChainTypeManager.setProtocolVersionDeadline, (getOldProtocolVersion(), 0)),
            value: 0
        });
    }

    /// @notice Double checking that the deadline has passed.
    function prepareGovernanceUpgradeTimerCheckCall() public virtual returns (Call[] memory calls) {
        require(upgradeAddresses.upgradeTimer != address(0), "upgradeTimer is zero");
        calls = new Call[](1);

        calls[0] = Call({
            target: upgradeAddresses.upgradeTimer,
            // Double checking that the deadline has passed.
            data: abi.encodeCall(GovernanceUpgradeTimer.checkDeadline, ()),
            value: 0
        });
    }

    function _buildCallProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        require(newConfig.contracts.transparentProxyAdmin != address(0), "transparentProxyAdmin not newConfigured");

        call = Call({
            target: newConfig.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress)
            ),
            value: 0
        });
    }

    function _buildCallProxyUpgradeAndCall(
        address proxyAddress,
        address newImplementationAddress,
        bytes memory data
    ) internal virtual returns (Call memory call) {
        require(newConfig.contracts.transparentProxyAdmin != address(0), "transparentProxyAdmin not newConfigured");

        call = Call({
            target: newConfig.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress, data)
            ),
            value: 0
        });
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    function mergeCalls(Call[] memory a, Call[] memory b) public pure returns (Call[] memory result) {
        result = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    function mergeCallsArray(Call[][] memory a) public pure returns (Call[] memory result) {
        uint256 resultLength;

        for (uint256 i; i < a.length; i++) {
            resultLength += a[i].length;
        }

        result = new Call[](resultLength);

        uint256 counter;
        for (uint256 i; i < a.length; i++) {
            for (uint256 j; j < a[i].length; j++) {
                result[counter] = a[i][j];
                counter++;
            }
        }
    }

    function mergeFacets(
        Diamond.FacetCut[] memory a,
        Diamond.FacetCut[] memory b
    ) public pure returns (Diamond.FacetCut[] memory result) {
        result = new Diamond.FacetCut[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
