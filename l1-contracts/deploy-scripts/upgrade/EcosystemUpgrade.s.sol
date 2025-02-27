// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "../Utils.sol";
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
import {L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_GATEWAY_SPECIFIC_UPGRADER} from "contracts/common/L2ContractAddresses.sol";
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
import {IL2GatewaySpecificUpgrader} from "contracts/common/interfaces/IL2GatewaySpecificUpgrader.sol";

interface IBridgehub {
    function chainTypeManager(uint256 chainId) external returns (address);

    function pauseMigration() external;
    function unpauseMigration() external;
}

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

// A subset of the ones used for tests
struct StateTransitionDeployedAddresses {
    address chainTypeManagerImplementation;
    address verifier;
    address adminFacet;
    address mailboxFacet;
    address executorFacet;
    address gettersFacet;
    address diamondInit;
    address genesisUpgrade;
    address defaultUpgrade;
    address validatorTimelock;
}

/// @notice Script used for default upgrade flow
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract EcosystemUpgrade is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // solhint-disable-next-line gas-struct-packing
    struct DeployedAddresses {
        BridgehubDeployedAddresses bridgehub;
        StateTransitionDeployedAddresses stateTransition;
        BridgesDeployedAddresses bridges;
        L1NativeTokenVaultAddresses vaults;
        DataAvailabilityDeployedAddresses daAddresses;
        ExpectedL2Addresses expectedL2Addresses;
        address chainAdmin;
        address accessControlRestrictionAddress;
        address validatorTimelock;
        address gatewayUpgrade;
        address create2Factory;
        address transitionaryOwner;
        address upgradeTimer;
        address bytecodesSupplier;
        address l2WrappedBaseTokenStore;
        address blobVersionedHashRetriever;
    }

    struct ExpectedL2Addresses {
        address expectedRollupL2DAValidator;
        address expectedValidiumL2DAValidator;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
    }

    // solhint-disable-next-line gas-struct-packing
    struct L1NativeTokenVaultAddresses {
        address l1NativeTokenVaultImplementation;
    }

    struct DataAvailabilityDeployedAddresses {
        address rollupDAManager;
        address l1RollupDAValidator;
        address l1ValidiumDAValidator;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address ctmDeploymentTrackerImplementation;
        address messageRootImplementation;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address l1AssetRouterImplementation;
        address l1NullifierImplementation;
        address bridgedStandardERC20Implementation;
        address bridgedTokenBeacon;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Config {
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
        ContractsConfig contracts;
        TokensConfig tokens;
        Gateway gateway;
    }

    // solhint-disable-next-line gas-struct-packing
    struct GeneratedData {
        bytes fixedForceDeploymentsData;
        bytes diamondCutData;
        bytes upgradeCutData;
    }

    // solhint-disable-next-line gas-struct-packing
    struct ContractsConfig {
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

    Config internal config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    uint256[] internal factoryDepsHashes;
    mapping(bytes32 => bool) internal isHashInFactoryDeps;

    EcosystemUpgradeConfig internal upgradeConfig;

    function initialize(string memory configPath, string memory _outputPath) public virtual {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);

        initializeConfig(configPath);
        initializeOldData();

        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    /// @notice Full default upgrade preparation flow
    function prepareEcosystemUpgrade() public virtual {
        deployEcosystemContracts();
        console.log("Ecosystem contracts are deployed!");
        publishBytecodes();
        console.log("Bytecodes published!");
        generateUpgradeData();
        console.log("Upgrade data generated!");
    }

    /// @notice Deploy everything that should be deployed
    function deployEcosystemContracts() public virtual {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        // TODO not needed?
        // deployBytecodesSupplier();

        deployBlobVersionedHashRetriever(); // TODO not needed?
        deployDualVerifier();
        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployGatewayUpgrade(); // TODO not needed?

        initializeExpectedL2Addresses();
        // TODO: can we remove DA redeploy? It isn't behind a proxy
        deployDAValidators();

        deployBridgehubImplementation();
        deployCTMDeploymentTrackerImplementation();
        deployMessageRootContractImplementation();

        deployL1NullifierImplementation();
        deployL1AssetRouterImplementation();
        deployBridgedStandardERC20Implementation();
        deployBridgedTokenBeacon(); // TODO not needed?
        deployL1NativeTokenVaultImplementation();
        deployErc20BridgeImplementation();

        deployChainTypeManagerContract();

        deployTransitionaryOwner(); // TODO unused?
        deployL2WrappedBaseTokenStore(); // TODO not needed?
        deployGovernanceUpgradeTimer(); // TODO not needed?

        // Additional (optional) configuration after deploy

        allowDAPair(
            addresses.daAddresses.rollupDAManager,
            addresses.daAddresses.l1RollupDAValidator,
            addresses.expectedL2Addresses.expectedRollupL2DAValidator
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
    function run() public virtual {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        IZKChain.Facet[] memory facets = IZKChain(config.contracts.eraDiamondProxy).facets();

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
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
        bool isOnGateway
    ) internal virtual returns (L2CanonicalTransaction memory transaction) {
        // Sanity check
        for (uint256 i; i < forceDeployments.length; i++) {
            require(isHashInFactoryDeps[forceDeployments[i].bytecodeHash], "Bytecode hash not in factory deps");
        }

        bytes memory gatewaySpecificUpgraderInput;
        if (!isOnGateway) {
            IL2ContractDeployer.ForceDeployment[] memory gatewaySpecificForceDeployments = abi.decode(
                config.gateway.additionalForceDeployments,
                (IL2ContractDeployer.ForceDeployment[])
            );
            // We need to propagate upgrade on
            gatewaySpecificUpgraderInput = abi.encodeCall(
                IL2GatewaySpecificUpgrader.upgradeIfGateway,
                (
                    config.gateway.chainTypeManagerOnGatewayAddress,
                    prepareNewChainCreationParamsForGateway(),
                    generateUpgradeCutData({isOnGateway: true}),
                    getOldProtocolVersion(),
                    getOldProtocolDeadline(),
                    getNewProtocolVersion(),
                    gatewaySpecificForceDeployments
                )
            );
        }

        bytes memory data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgrade,
            (forceDeployments, L2_GATEWAY_SPECIFIC_UPGRADER, gatewaySpecificUpgraderInput)
        );

        transaction = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(address(L2_COMPLEX_UPGRADER_ADDR))),
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
            facetCuts = abi.decode(config.gateway.facetCutsData, (Diamond.FacetCut[]));
        } else {
            facetCuts = getFacetCuts();
        }
        facetCuts = mergeFacets(getFacetCutsForDeletion(), facetCuts);

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
        });

        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments();

        // Additional force deployments after Gateway
        IL2ContractDeployer.ForceDeployment[]
            memory additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](4);
        additionalForceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode()),
            newAddress: addresses.expectedL2Addresses.l2SharedBridgeLegacyImpl,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[1] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readStandardERC20Bytecode()),
            newAddress: addresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[2] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode()),
            newAddress: addresses.expectedL2Addresses.expectedRollupL2DAValidator,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[3] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode()),
            newAddress: addresses.expectedL2Addresses.expectedValidiumL2DAValidator,
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
            ? config.gateway.gatewayStateTransition.verifier
            : addresses.stateTransition.verifier;
        address defaultUpgradeAddress = isOnGateway
            ? config.gateway.gatewayStateTransition.defaultUpgrade
            : addresses.stateTransition.defaultUpgrade;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeUpgradeTx(forceDeployments, isOnGateway),
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            evmEmulatorHash: config.contracts.evmEmulatorHash,
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
            generatedData.upgradeCutData = abi.encode(upgradeCutData);
            upgradeConfig.upgradeCutPrepared = true;
        }
    }

    function getEcosystemAdmin() external virtual returns (address) {
        return config.ecosystemAdminAddress;
    }

    function initializeConfig(string memory configPath) internal virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

        config.contracts.maxNumberOfChains = toml.readUint("$.contracts.max_number_of_chains");
        config.contracts.create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            config.contracts.create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        config.contracts.bytecodesSupplierAddress = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");
        config.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.genesisRoot = toml.readBytes32("$.contracts.genesis_root");
        config.contracts.genesisRollupLeafIndex = toml.readUint("$.contracts.genesis_rollup_leaf_index");
        config.contracts.genesisBatchCommitment = toml.readBytes32("$.contracts.genesis_batch_commitment");
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

        config.contracts.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");

        config.ownerAddress = Bridgehub(config.contracts.bridgehubProxyAddress).owner();
        config.contracts.stateTransitionManagerAddress = IBridgehub(config.contracts.bridgehubProxyAddress)
            .chainTypeManager(config.eraChainId);
        config.contracts.l1AssetRouterProxyAddress = Bridgehub(config.contracts.bridgehubProxyAddress).sharedBridge(); // TODO old?

        config.contracts.l1NativeTokenVaultProxy = address(
            L1AssetRouter(config.contracts.l1AssetRouterProxyAddress).nativeTokenVault()
        );
        config.contracts.l1NullifierAddress = address(
            L1AssetRouter(config.contracts.l1AssetRouterProxyAddress).L1_NULLIFIER()
        );

        config.contracts.ctmDeploymentTrackerProxy = address(
            Bridgehub(config.contracts.bridgehubProxyAddress).l1CtmDeployer()
        );
        config.contracts.messageRootProxy = address(Bridgehub(config.contracts.bridgehubProxyAddress).messageRoot());

        config.contracts.eraDiamondProxy = ChainTypeManager(config.contracts.stateTransitionManagerAddress)
            .getHyperchain(config.eraChainId);
        config.contracts.legacyErc20BridgeAddress = address(
            L1AssetRouter(config.contracts.l1AssetRouterProxyAddress).legacyBridge()
        );
        config.contracts.oldValidatorTimelock = ChainTypeManager(config.contracts.stateTransitionManagerAddress)
            .validatorTimelock();

        config.contracts.transparentProxyAdmin = toml.readAddress("$.contracts.transparent_proxy_admin");

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
        config.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");

        config.ecosystemAdminAddress = Bridgehub(config.contracts.bridgehubProxyAddress).admin();

        config.gateway.facetCutsData = abi.encode(new Diamond.DiamondCutData[](0)); // TODO
        config.gateway.additionalForceDeployments = abi.encode(new IL2ContractDeployer.ForceDeployment[](0)); // TODO

        config.gateway.gatewayStateTransition.chainTypeManagerImplementation = toml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_implementation_addr"
        );
        config.gateway.gatewayStateTransition.verifier = toml.readAddress(
            "$.gateway.gateway_state_transition.verifier_addr"
        );
        config.gateway.gatewayStateTransition.adminFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.admin_facet_addr"
        );
        config.gateway.gatewayStateTransition.mailboxFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.mailbox_facet_addr"
        );
        config.gateway.gatewayStateTransition.executorFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.executor_facet_addr"
        );
        config.gateway.gatewayStateTransition.gettersFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.getters_facet_addr"
        );
        config.gateway.gatewayStateTransition.diamondInit = toml.readAddress(
            "$.gateway.gateway_state_transition.diamond_init_addr"
        );
        config.gateway.gatewayStateTransition.genesisUpgrade = toml.readAddress(
            "$.gateway.gateway_state_transition.genesis_upgrade_addr"
        );
        config.gateway.gatewayStateTransition.defaultUpgrade = toml.readAddress(
            "$.gateway.gateway_state_transition.default_upgrade_addr"
        );
        config.gateway.gatewayStateTransition.validatorTimelock = toml.readAddress(
            "$.gateway.gateway_state_transition.validator_timelock_addr"
        );

        config.gateway.chainTypeManagerOnGatewayAddress = toml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_proxy_addr"
        );
    }

    function initializeOldData() internal virtual {
        config.contracts.newProtocolVersion = getNewProtocolVersion();
        config.contracts.oldProtocolVersion = getOldProtocolVersion();

        uint256 ctmProtocolVersion = ChainTypeManager(config.contracts.stateTransitionManagerAddress).protocolVersion();
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );

        config.contracts.oldValidatorTimelock = ChainTypeManager(config.contracts.stateTransitionManagerAddress)
            .validatorTimelock();

        // In the future this value will be populated with the new shared bridge, but since the version on the CTM is the old one, the old bridge is stored here as well.
        config.contracts.l1LegacySharedBridge = Bridgehub(config.contracts.bridgehubProxyAddress).sharedBridge();
    }

    function generateFixedForceDeploymentsData() internal virtual {
        require(upgradeConfig.expectedL2AddressesInitialized, "Expected L2 addresses not initialized");
        FixedForceDeploymentsData memory forceDeploymentsData = prepareFixedForceDeploymentsData();

        generatedData.fixedForceDeploymentsData = abi.encode(forceDeploymentsData);
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    function initializeExpectedL2Addresses() internal virtual {
        address aliasedGovernance = AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress);

        addresses.expectedL2Addresses = ExpectedL2Addresses({
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
        return config.governanceUpgradeTimerInitialDelay;
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
            abi.decode(config.gateway.facetCutsData, (Diamond.FacetCut[]));
        } else {
            facetCuts = getFacetCuts();
        }

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

        address verifierAddress = isOnGateway
            ? config.gateway.gatewayStateTransition.verifier
            : addresses.stateTransition.verifier;
        address blobVersionedHashRetrieverAddress = isOnGateway ? ADDRESS_ONE : addresses.blobVersionedHashRetriever; // Not needed on Gateway
        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(verifierAddress),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: config.contracts.bootloaderHash,
            l2DefaultAccountBytecodeHash: config.contracts.defaultAAHash,
            l2EvmEmulatorBytecodeHash: config.contracts.evmEmulatorHash,
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            feeParams: feeParams,
            blobVersionedHashRetriever: blobVersionedHashRetrieverAddress
        });

        address diamondInitAddress = isOnGateway
            ? config.gateway.gatewayStateTransition.diamondInit
            : addresses.stateTransition.diamondInit;
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: diamondInitAddress,
            initCalldata: abi.encode(initializeData)
        });

        if (!isOnGateway) {
            generatedData.diamondCutData = abi.encode(diamondCut);
            upgradeConfig.diamondCutPrepared = true;
        }

        return (diamondCut);
    }

    function prepareNewChainCreationParams() internal virtual returns (ChainCreationParams memory chainCreationParams) {
        require(upgradeConfig.fixedForceDeploymentsDataGenerated, "Force deployment data not generated");
        require(upgradeConfig.diamondCutPrepared, "Diamond cut not prepared");

        Diamond.DiamondCutData memory diamondCut = abi.decode(generatedData.diamondCutData, (Diamond.DiamondCutData));

        chainCreationParams = ChainCreationParams({
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: generatedData.fixedForceDeploymentsData
        });
    }

    function prepareNewChainCreationParamsForGateway()
        internal
        virtual
        returns (ChainCreationParams memory chainCreationParams)
    {
        require(upgradeConfig.fixedForceDeploymentsDataGenerated, "Force deployment data not generated");

        Diamond.DiamondCutData memory diamondCut = prepareDiamondCutData({isOnGateway: true});

        chainCreationParams = ChainCreationParams({
            genesisUpgrade: config.gateway.gatewayStateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: generatedData.fixedForceDeploymentsData
        });
    }

    function prepareFixedForceDeploymentsData() public view virtual returns (FixedForceDeploymentsData memory data) {
        require(config.ownerAddress != address(0), "owner not set");

        data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId, // TODO: what should be used if it is on Gateway?
            eraChainId: config.eraChainId,
            l1AssetRouter: config.contracts.l1AssetRouterProxyAddress,
            l2TokenProxyBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readBeaconProxyBytecode()
            ),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress),
            maxNumberOfZKChains: config.contracts.maxNumberOfChains,
            bridgehubBytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readBridgehubBytecode()),
            l2AssetRouterBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readL2AssetRouterBytecode()
            ),
            l2NtvBytecodeHash: L2ContractHelper.hashL2Bytecode(
                L2ContractsBytecodesLib.readL2NativeTokenVaultBytecode()
            ),
            messageRootBytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readMessageRootBytecode()),
            l2SharedBridgeLegacyImpl: addresses.expectedL2Addresses.l2SharedBridgeLegacyImpl,
            l2BridgedStandardERC20Impl: addresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            dangerousTestOnlyForcedBeacon: address(0)
        });
    }

    function saveOutput(string memory outputPath) internal virtual {
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
            "chaint_type_manager_implementation_addr",
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
            "contracts_config",
            "diamond_init_max_l2_gas_per_batch",
            config.contracts.diamondInitMaxL2GasPerBatch
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_batch_overhead_l1_gas",
            config.contracts.diamondInitBatchOverheadL1Gas
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_max_pubdata_per_batch",
            config.contracts.diamondInitMaxPubdataPerBatch
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_minimal_l2_gas_price",
            config.contracts.diamondInitMinimalL2GasPrice
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_priority_tx_max_pubdata",
            config.contracts.diamondInitPriorityTxMaxPubdata
        );
        vm.serializeUint(
            "contracts_config",
            "diamond_init_pubdata_pricing_mode",
            uint256(config.contracts.diamondInitPubdataPricingMode)
        );
        vm.serializeUint("contracts_config", "priority_tx_max_gas_limit", config.contracts.priorityTxMaxGasLimit);
        vm.serializeBytes32(
            "contracts_config",
            "recursion_circuits_set_vks_hash",
            config.contracts.recursionCircuitsSetVksHash
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_leaf_level_vk_hash",
            config.contracts.recursionLeafLevelVkHash
        );
        vm.serializeBytes32(
            "contracts_config",
            "recursion_node_level_vk_hash",
            config.contracts.recursionNodeLevelVkHash
        );

        vm.serializeAddress(
            "contracts_config",
            "expected_rollup_l2_da_validator",
            addresses.expectedL2Addresses.expectedRollupL2DAValidator
        );
        vm.serializeAddress(
            "contracts_config",
            "expected_validium_l2_da_validator",
            addresses.expectedL2Addresses.expectedValidiumL2DAValidator
        );
        vm.serializeBytes("contracts_config", "diamond_cut_data", generatedData.diamondCutData);

        vm.serializeBytes("contracts_config", "force_deployments_data", generatedData.fixedForceDeploymentsData);

        vm.serializeUint("contracts_config", "new_protocol_version", config.contracts.newProtocolVersion);

        vm.serializeUint("contracts_config", "old_protocol_version", config.contracts.oldProtocolVersion);

        vm.serializeAddress("contracts_config", "old_validator_timelock", config.contracts.oldValidatorTimelock);

        string memory contractsConfig = vm.serializeAddress(
            "contracts_config",
            "l1_legacy_shared_bridge",
            config.contracts.l1LegacySharedBridge
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
            addresses.daAddresses.l1ValidiumDAValidator
        );
        vm.serializeAddress(
            "deployed_addresses",
            "l2_wrapped_base_token_store_addr",
            addresses.l2WrappedBaseTokenStore
        );
        vm.serializeAddress("deployed_addresses", "l1_gateway_upgrade", addresses.gatewayUpgrade);
        vm.serializeAddress("deployed_addresses", "l1_transitionary_owner", addresses.transitionaryOwner);
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            addresses.upgradeTimer
        );

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", config.contracts.create2FactorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);

        vm.serializeBytes("root", "governance_calls", new bytes(0)); // Will be populated later

        vm.serializeBytes("root", "chain_upgrade_diamond_cut", generatedData.upgradeCutData);

        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    function publishBytecodes() public virtual {
        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        uint256[] memory factoryDeps = new uint256[](allDeps.length);
        require(factoryDeps.length <= 64, "Too many deps");

        BytecodePublisher.publishBytecodesInBatches(
            BytecodesSupplier(config.contracts.bytecodesSupplierAddress),
            allDeps
        );

        for (uint256 i = 0; i < allDeps.length; i++) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(allDeps[i]);
            factoryDeps[i] = uint256(bytecodeHash);
            isHashInFactoryDeps[bytecodeHash] = true;
        }

        // Double check for consistency:
        require(bytes32(factoryDeps[0]) == config.contracts.bootloaderHash, "bootloader hash factory dep mismatch");
        require(bytes32(factoryDeps[1]) == config.contracts.defaultAAHash, "default aa hash factory dep mismatch");
        require(bytes32(factoryDeps[2]) == config.contracts.evmEmulatorHash, "EVM emulator hash factory dep mismatch");

        factoryDepsHashes = factoryDeps;

        upgradeConfig.factoryDepsPublished = true;
    }

    // Permissioned actions

    function setChainTypeManagerInValidatorTimelock() public virtual {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        if (address(validatorTimelock.chainTypeManager()) != config.contracts.stateTransitionManagerAddress) {
            vm.broadcast(msg.sender);
            validatorTimelock.setChainTypeManager(IChainTypeManager(config.contracts.stateTransitionManagerAddress));
        }
        console.log("ChainTypeManager set in ValidatorTimelock");
    }

    function _transferOwnershipToGovernance(address target) internal virtual {
        if (Ownable2StepUpgradeable(target).owner() != config.ownerAddress) {
            Ownable2StepUpgradeable(target).transferOwnership(addresses.transitionaryOwner);
            TransitionaryOwner(addresses.transitionaryOwner).claimOwnershipAndGiveToGovernance(target);
        }
    }

    function _transferOwnershipToEcosystemAdmin(address target) internal virtual {
        if (Ownable2StepUpgradeable(target).owner() != config.ecosystemAdminAddress) {
            // Is agile enough to accept ownership quickly
            Ownable2StepUpgradeable(target).transferOwnership(config.ecosystemAdminAddress);
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

    function deployBlobVersionedHashRetriever() internal virtual {
        bytes memory bytecode = hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
        address contractAddress = deployViaCreate2(bytecode);
        console.log("BlobVersionedHashRetriever deployed at:", contractAddress);
        addresses.blobVersionedHashRetriever = contractAddress;
    }

    function instantiateCreate2Factory() internal virtual {
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

    function deployBytecodesSupplier() internal virtual {
        address contractAddress = deployViaCreate2(type(BytecodesSupplier).creationCode);
        console.log("BytecodesSupplier deployed at:", contractAddress);
        notifyAboutDeployment(contractAddress, "BytecodesSupplier", hex"");
        addresses.bytecodesSupplier = contractAddress;
    }

    function deployDualVerifier() internal virtual {
        address verifierFflonk = deployVerifierFflonk();
        address verifierPlonk = deployVerifierPlonk();
        bytes memory code;
        string memory contractName;
        if (config.testnetVerifier) {
            code = type(TestnetVerifier).creationCode;
            contractName = "TestnetVerifier";
        } else {
            code = type(DualVerifier).creationCode;
            contractName = "DualVerifier";
        }
        code = abi.encodePacked(code, abi.encode(verifierFflonk, verifierPlonk));
        address contractAddress = deployViaCreate2(code);
        notifyAboutDeployment(contractAddress, contractName, abi.encode(verifierFflonk, verifierPlonk));
        addresses.stateTransition.verifier = contractAddress;
    }

    function deployVerifierFflonk() internal virtual returns (address contractAddress) {
        bytes memory code = type(VerifierFflonk).creationCode;
        contractAddress = deployViaCreate2(code);
        notifyAboutDeployment(contractAddress, "VerifierFflonk", hex"");
    }

    function deployVerifierPlonk() internal virtual returns (address contractAddress) {
        bytes memory code = type(VerifierPlonk).creationCode;
        contractAddress = deployViaCreate2(code);
        notifyAboutDeployment(contractAddress, "VerifierPlonk", hex"");
    }
    function deployDefaultUpgrade() internal virtual {
        address contractAddress = deployViaCreate2(type(DefaultUpgrade).creationCode);
        notifyAboutDeployment(contractAddress, "DefaultUpgrade", hex"");
        addresses.stateTransition.defaultUpgrade = contractAddress;
    }

    function deployGenesisUpgrade() internal virtual {
        bytes memory bytecode = abi.encodePacked(type(L1GenesisUpgrade).creationCode);
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(contractAddress, "L1GenesisUpgrade", hex"");
        addresses.stateTransition.genesisUpgrade = contractAddress;
    }

    function deployGatewayUpgrade() internal virtual {
        bytes memory bytecode = abi.encodePacked(type(GatewayUpgrade).creationCode);
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(contractAddress, "GatewayUpgrade", hex"");

        addresses.gatewayUpgrade = contractAddress;
    }

    function deployDAValidators() internal virtual {
        // Note, that here we use the `msg.sender` address, while the final owner should be the decentralized governance.
        // The ownership will be transferred later.
        address rollupDAManager = address(
            create2WithDeterministicOwner(type(RollupDAManager).creationCode, msg.sender)
        );
        addresses.daAddresses.rollupDAManager = rollupDAManager;
        notifyAboutDeployment(rollupDAManager, "RollupDAManager", hex"");

        if (RollupDAManager(rollupDAManager).owner() != address(msg.sender)) {
            if (RollupDAManager(rollupDAManager).pendingOwner() == address(msg.sender)) {
                vm.broadcast(msg.sender);
                RollupDAManager(rollupDAManager).acceptOwnership();
            } else {
                require(
                    RollupDAManager(rollupDAManager).owner() == config.ownerAddress,
                    "Ownership was not set correctly"
                );
            }
        }

        // This contract is located in the `da-contracts` folder, we output it the same way for consistency/ease of use.
        address rollupDAValidator = deployViaCreate2(Utils.readRollupDAValidatorBytecode());
        notifyAboutDeployment(rollupDAValidator, "RollupL1DAValidator", hex"");
        addresses.daAddresses.l1RollupDAValidator = rollupDAValidator;

        address validiumDAValidator = deployViaCreate2(type(ValidiumL1DAValidator).creationCode);
        notifyAboutDeployment(validiumDAValidator, "ValidiumL1DAValidator", hex"");
        addresses.daAddresses.l1ValidiumDAValidator = validiumDAValidator;
    }

    function deployValidatorTimelock() internal virtual {
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        bytes memory bytecode = abi.encodePacked(
            type(ValidatorTimelock).creationCode,
            abi.encode(config.deployerAddress, executionDelay)
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(contractAddress, "ValidatorTimelock", abi.encode(config.deployerAddress, executionDelay));
        addresses.validatorTimelock = contractAddress;
    }

    function deployBridgehubImplementation() internal virtual {
        bytes memory bridgeHubBytecode = abi.encodePacked(
            type(Bridgehub).creationCode,
            abi.encode(config.l1ChainId, config.ownerAddress, config.contracts.maxNumberOfChains)
        );
        address bridgehubImplementation = deployViaCreate2(bridgeHubBytecode);
        notifyAboutDeployment(
            bridgehubImplementation,
            "Bridgehub",
            abi.encode(config.l1ChainId, config.ownerAddress, config.contracts.maxNumberOfChains),
            "Bridgehub Implementation"
        );
        addresses.bridgehub.bridgehubImplementation = bridgehubImplementation;
    }

    function deployMessageRootContractImplementation() internal virtual {
        bytes memory messageRootBytecode = abi.encodePacked(
            type(MessageRoot).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress)
        );
        address messageRootImplementation = deployViaCreate2(messageRootBytecode);
        notifyAboutDeployment(
            messageRootImplementation,
            "MessageRoot",
            abi.encode(config.contracts.bridgehubProxyAddress),
            "Message Root Implementation"
        );
        addresses.bridgehub.messageRootImplementation = messageRootImplementation;
    }

    function deployCTMDeploymentTrackerImplementation() internal virtual {
        bytes memory ctmDTBytecode = abi.encodePacked(
            type(CTMDeploymentTracker).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress, config.contracts.l1AssetRouterProxyAddress)
        );
        address ctmDTImplementation = deployViaCreate2(ctmDTBytecode);
        notifyAboutDeployment(
            ctmDTImplementation,
            "CTMDeploymentTracker",
            abi.encode(config.contracts.bridgehubProxyAddress, config.contracts.l1AssetRouterProxyAddress),
            "CTM Deployment Tracker Implementation"
        );
        addresses.bridgehub.ctmDeploymentTrackerImplementation = ctmDTImplementation;
    }

    function deployChainTypeManagerContract() internal virtual {
        deployStateTransitionDiamondFacets();
        deployChainTypeManagerImplementation();
    }

    function deployStateTransitionDiamondFacets() internal virtual {
        address executorFacet = deployViaCreate2(
            abi.encodePacked(type(ExecutorFacet).creationCode, abi.encode(config.l1ChainId))
        );
        notifyAboutDeployment(executorFacet, "ExecutorFacet", abi.encode(config.l1ChainId));
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(
            abi.encodePacked(
                type(AdminFacet).creationCode,
                abi.encode(config.l1ChainId, addresses.daAddresses.rollupDAManager)
            )
        );
        notifyAboutDeployment(
            adminFacet,
            "AdminFacet",
            abi.encode(config.l1ChainId, addresses.daAddresses.rollupDAManager)
        );
        addresses.stateTransition.adminFacet = adminFacet;

        address mailboxFacet = deployViaCreate2(
            abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(config.eraChainId, config.l1ChainId))
        );
        notifyAboutDeployment(mailboxFacet, "MailboxFacet", abi.encode(config.eraChainId, config.l1ChainId));
        addresses.stateTransition.mailboxFacet = mailboxFacet;

        address gettersFacet = deployViaCreate2(type(GettersFacet).creationCode);
        notifyAboutDeployment(gettersFacet, "GettersFacet", hex"");
        addresses.stateTransition.gettersFacet = gettersFacet;

        address diamondInit = deployViaCreate2(type(DiamondInit).creationCode);
        notifyAboutDeployment(diamondInit, "DiamondInit", hex"");
        addresses.stateTransition.diamondInit = diamondInit;
    }

    function deployChainTypeManagerImplementation() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(ChainTypeManager).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress)
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            contractAddress,
            "ChainTypeManager",
            abi.encode(config.contracts.bridgehubProxyAddress),
            "ChainTypeManagerImplementation"
        );
        addresses.stateTransition.chainTypeManagerImplementation = contractAddress;
    }

    function deployL1NullifierImplementation() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(L1Nullifier).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(config.contracts.bridgehubProxyAddress, config.eraChainId, config.contracts.eraDiamondProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            contractAddress,
            "L1Nullifier",
            abi.encode(config.contracts.bridgehubProxyAddress, config.eraChainId, config.contracts.eraDiamondProxy),
            "L1NullifierImplementation"
        );
        addresses.bridges.l1NullifierImplementation = contractAddress;
    }

    function deployL1AssetRouterImplementation() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(L1AssetRouter).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                config.contracts.bridgehubProxyAddress,
                config.contracts.l1NullifierAddress,
                config.eraChainId,
                config.contracts.eraDiamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            contractAddress,
            "L1AssetRouter",
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                config.contracts.bridgehubProxyAddress,
                config.contracts.l1NullifierAddress,
                config.eraChainId,
                config.contracts.eraDiamondProxy
            ),
            "L1AssetRouterImplementation"
        );
        addresses.bridges.l1AssetRouterImplementation = contractAddress;
    }

    function deployErc20BridgeImplementation() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(L1ERC20Bridge).creationCode,
            abi.encode(
                config.contracts.l1NullifierAddress,
                config.contracts.l1AssetRouterProxyAddress,
                config.contracts.l1NativeTokenVaultProxy,
                config.eraChainId
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            contractAddress,
            "L1ERC20Bridge",
            abi.encode(
                config.contracts.l1NullifierAddress,
                config.contracts.l1AssetRouterProxyAddress,
                config.contracts.l1NativeTokenVaultProxy,
                config.eraChainId
            ),
            "Erc20BridgeImplementation"
        );
        addresses.bridges.erc20BridgeImplementation = contractAddress;
    }

    function deployBridgedStandardERC20Implementation() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(BridgedStandardERC20).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode()
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(contractAddress, "BridgedStandardERC20", hex"");
        addresses.bridges.bridgedStandardERC20Implementation = contractAddress;
    }

    function deployBridgedTokenBeacon() internal virtual {
        bytes memory initCode = abi.encodePacked(
            type(UpgradeableBeacon).creationCode,
            abi.encode(addresses.bridges.bridgedStandardERC20Implementation)
        );

        address beacon = create2WithDeterministicOwner(initCode, config.ownerAddress);
        notifyAboutDeployment(
            beacon,
            "UpgradeableBeacon",
            abi.encode(addresses.bridges.bridgedStandardERC20Implementation)
        );
        addresses.bridges.bridgedTokenBeacon = beacon;
    }

    function deployL1NativeTokenVaultImplementation() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(L1NativeTokenVault).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                config.contracts.l1AssetRouterProxyAddress,
                config.contracts.l1NullifierAddress
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            contractAddress,
            "L1NativeTokenVault",
            abi.encode(
                config.tokens.tokenWethAddress,
                config.contracts.l1AssetRouterProxyAddress,
                config.contracts.l1NullifierAddress
            ),
            "L1NativeTokenVaultImplementation"
        );
        addresses.vaults.l1NativeTokenVaultImplementation = contractAddress;
    }

    function deployGovernanceUpgradeTimer() internal virtual {
        uint256 initialDelay = config.governanceUpgradeTimerInitialDelay;

        uint256 maxAdditionalDelay = 2 weeks;

        // It may make sense to have a separate admin there, but
        // using the same as bridgehub is just as fine.
        address bridgehubAdmin = Bridgehub(config.contracts.bridgehubProxyAddress).admin();

        bytes memory bytecode = abi.encodePacked(
            type(GovernanceUpgradeTimer).creationCode,
            abi.encode(initialDelay, maxAdditionalDelay, config.ownerAddress, config.ecosystemAdminAddress)
        );

        addresses.upgradeTimer = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            addresses.upgradeTimer,
            "GovernanceUpgradeTimer",
            abi.encode(initialDelay, maxAdditionalDelay, config.ownerAddress, config.ecosystemAdminAddress)
        );
    }

    function deployL2WrappedBaseTokenStore() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(L2WrappedBaseTokenStore).creationCode,
            // We set a temoprary admin there. This is needed for easier/quicker setting of
            // wrapped base tokens. The ownership MUST be transferred to a trusted admin before the
            // decentralized upgrade voting starts.
            abi.encode(config.ownerAddress, msg.sender)
        );

        addresses.l2WrappedBaseTokenStore = deployViaCreate2(bytecode);
        notifyAboutDeployment(
            addresses.l2WrappedBaseTokenStore,
            "L2WrappedBaseTokenStore",
            abi.encode(config.ownerAddress, msg.sender)
        );
    }

    function deployTransitionaryOwner() internal virtual {
        bytes memory bytecode = abi.encodePacked(
            type(TransitionaryOwner).creationCode,
            abi.encode(config.ownerAddress)
        );

        addresses.transitionaryOwner = deployViaCreate2(bytecode);

        notifyAboutDeployment(addresses.transitionaryOwner, "TransitionaryOwner", abi.encode(config.ownerAddress));
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
        calls = preparePauseGatewayMigrationsCall();
    }

    /// @notice The second step of upgrade. By default it is actual upgrade
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](5);
        allCalls[0] = prepareUpgradeProxiesCalls();
        allCalls[1] = prepareNewChainCreationParamsCall();
        allCalls[2] = provideSetNewVersionUpgradeCall();
        allCalls[3] = prepareUnpauseGatewayMigrationsCall();
        allCalls[4] = prepareContractsConfigurationCalls();
        // TODO not needed?
        //allCalls[5] = prepareGovernanceUpgradeTimerCheckCall();

        calls = mergeCallsArray(allCalls);
    }

    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {
        require(
            config.contracts.stateTransitionManagerAddress != address(0),
            "stateTransitionManagerAddress is zero in config"
        );

        // Just retrieved it from the contract
        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCut = abi.decode(generatedData.upgradeCutData, (Diamond.DiamondCutData));
        Call memory ctmCall = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(
                ChainTypeManager.setNewVersionUpgrade,
                (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
            ),
            value: 0
        });

        // The call that will start the timer till the end of the upgrade.
        // TODO
        Call memory timerCall = Call({
            target: addresses.upgradeTimer,
            data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()),
            value: 0
        });

        calls = new Call[](2);
        calls[0] = ctmCall;
        calls[1] = timerCall;
    }

    function preparePauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(config.contracts.bridgehubProxyAddress != address(0), "bridgehubProxyAddress is zero in config");

        result = new Call[](1);
        result[0] = Call({
            target: config.contracts.bridgehubProxyAddress,
            value: 0,
            data: abi.encodeCall(IBridgehub.pauseMigration, ())
        });
    }

    function prepareUnpauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(config.contracts.bridgehubProxyAddress != address(0), "bridgehubProxyAddress is zero in config");

        result = new Call[](1);
        result[0] = Call({
            target: config.contracts.bridgehubProxyAddress,
            value: 0,
            data: abi.encodeCall(IBridgehub.unpauseMigration, ())
        });
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
            config.contracts.stateTransitionManagerAddress != address(0),
            "stateTransitionManagerAddress is zero in config"
        );
        calls = new Call[](1);

        calls[0] = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(ChainTypeManager.setChainCreationParams, (prepareNewChainCreationParams())),
            value: 0
        });
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public virtual returns (Call[] memory calls) {
        // TODO
        calls = new Call[](8);

        calls[0] = _buildCallProxyUpgrade(
            config.contracts.stateTransitionManagerAddress,
            addresses.stateTransition.chainTypeManagerImplementation
        );

        calls[1] = _buildCallProxyUpgrade(
            config.contracts.bridgehubProxyAddress,
            addresses.bridgehub.bridgehubImplementation
        );

        // Note, that we do not need to run the initializer
        calls[2] = _buildCallProxyUpgrade(
            config.contracts.l1NullifierAddress,
            addresses.bridges.l1NullifierImplementation
        );

        calls[3] = _buildCallProxyUpgrade(
            config.contracts.legacyErc20BridgeAddress,
            addresses.bridges.erc20BridgeImplementation
        );

        calls[4] = _buildCallProxyUpgrade(
            config.contracts.l1AssetRouterProxyAddress,
            addresses.bridges.l1AssetRouterImplementation
        );

        calls[5] = _buildCallProxyUpgrade(
            config.contracts.l1NativeTokenVaultProxy,
            addresses.vaults.l1NativeTokenVaultImplementation
        );

        calls[6] = _buildCallProxyUpgrade(
            config.contracts.ctmDeploymentTrackerProxy,
            addresses.bridgehub.ctmDeploymentTrackerImplementation
        );

        calls[7] = _buildCallProxyUpgrade(
            config.contracts.messageRootProxy,
            addresses.bridgehub.messageRootImplementation
        );
    }

    /// @notice Additional calls to configure contracts
    function prepareContractsConfigurationCalls() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        // TODO not needed?
        calls[0] = Call({
            target: config.contracts.stateTransitionManagerAddress,
            // Making the old protocol version no longer invalid
            data: abi.encodeCall(ChainTypeManager.setProtocolVersionDeadline, (getOldProtocolVersion(), 0)),
            value: 0
        });
    }

    /// @notice Double checking that the deadline has passed.
    function prepareGovernanceUpgradeTimerCheckCall() public virtual returns (Call[] memory calls) {
        require(addresses.upgradeTimer != address(0), "upgradeTimer is zero");
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.upgradeTimer,
            // Double checking that the deadline has passed.
            data: abi.encodeCall(GovernanceUpgradeTimer.checkDeadline, ()),
            value: 0
        });
    }

    function _buildCallProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        require(config.contracts.transparentProxyAdmin != address(0), "transparentProxyAdmin not configured");

        call = Call({
            target: config.contracts.transparentProxyAdmin,
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
        require(config.contracts.transparentProxyAdmin != address(0), "transparentProxyAdmin not configured");

        call = Call({
            target: config.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress, data)
            ),
            value: 0
        });
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.contracts.create2FactorySalt, addresses.create2Factory);
    }

    function create2WithDeterministicOwner(bytes memory initCode, address owner) internal returns (address) {
        bytes memory creatorInitCode = abi.encodePacked(
            type(Create2AndTransfer).creationCode,
            abi.encode(initCode, config.contracts.create2FactorySalt, owner)
        );

        address deployerAddr = deployViaCreate2(creatorInitCode);

        return Create2AndTransfer(deployerAddr).deployedAddress();
    }

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
        if (constructorParams.length == 0) {
            forgeMessage = string.concat("forge verify-contract ", vm.toString(contractAddr), " ", contractName);
        } else {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                contractName,
                " --constructor-args ",
                vm.toString(constructorParams)
            );
        }

        console.log(forgeMessage);
    }

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
    function test() internal {}
}
