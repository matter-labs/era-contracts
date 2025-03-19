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
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
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

import {FixedForceDeploymentsData, DeployedAddresses, ContractsConfig, TokensConfig} from "../DeployUtils.s.sol";
import {DeployL1Script} from "../DeployL1.s.sol";

/// @notice Script used for default upgrade flow
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract EcosystemUpgrade is Script, DeployL1Script {
    using stdToml for string;

    // solhint-disable-next-line gas-struct-packing
    struct UpgradeDeployedAddresses {
        ExpectedL2Addresses expectedL2Addresses;
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
    struct AdditionalConfig {
        // This is the address of the ecosystem admin.
        // Note, that it is not the owner, but rather the address that is responsible
        // for facilitating partially trusted, but not critical tasks.
        address ecosystemAdminAddress;
        uint256 governanceUpgradeTimerInitialDelay;
        //uint256 newProtocolVersion;
        uint256 oldProtocolVersion;
        address oldValidatorTimelock;
    }

    // solhint-disable-next-line gas-struct-packing
    struct NewlyGeneratedData {
        bytes fixedForceDeploymentsData;
        bytes diamondCutData;
        bytes upgradeCutData;
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

    AdditionalConfig internal newConfig;
    NewlyGeneratedData internal newlyGeneratedData;
    UpgradeDeployedAddresses internal upgradeAddresses;

    uint256[] internal factoryDepsHashes;
    mapping(bytes32 => bool) internal isHashInFactoryDeps;

    EcosystemUpgradeConfig internal upgradeConfig;

    function initialize(string memory newConfigPath, string memory _outputPath) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);

        initializeConfig(newConfigPath);

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

        deployVerifiers();
        // add custom upgrade deployment here instead of DefaultUpgrade if needed.
        (addresses.stateTransition.defaultUpgrade) = deploySimpleContract("DefaultUpgrade");
        (addresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade");

        addresses.bridgehub.bridgehubImplementation = deploySimpleContract("Bridgehub");

        addresses.bridges.l1NullifierImplementation = deploySimpleContract("L1Nullifier");
        addresses.bridges.l1AssetRouterImplementation = deploySimpleContract("L1AssetRouter");
        addresses.vaults.l1NativeTokenVaultImplementation = deploySimpleContract("L1NativeTokenVault");

        deployStateTransitionDiamondFacets();
        addresses.stateTransition.chainTypeManagerImplementation = deploySimpleContract("ChainTypeManager");

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    /// @notice Generate data required for the upgrade
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Important, this must come after the initializeExpectedL2Addresses
        generateFixedForceDeploymentsData();
        console.log("Generated fixed force deployments data");
        getDiamondCutData(addresses.stateTransition); //{isOnGateway: false});
        newlyGeneratedData.diamondCutData = config.contracts.diamondCutData;
        console.log("Prepared diamond cut data");
        generateUpgradeCutData(addresses.stateTransition); //{isOnGateway: false});
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
        return config.ownerAddress;
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        address eraDiamondProxy = ChainTypeManager(addresses.stateTransition.chainTypeManagerProxy).getHyperchain(
            config.eraChainId
        );
        IZKChain.Facet[] memory facets = IZKChain(eraDiamondProxy).facets();

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
        return config.contracts.latestProtocolVersion;
    }

    function getProtocolUpgradeNonce() public virtual returns (uint256) {
        return (getNewProtocolVersion() >> 32);
    }

    function getOldProtocolDeadline() public virtual returns (uint256) {
        // Note, that it is this way by design, on stage2 it
        // will be set to 0
        return type(uint256).max;
    }

    function getOldProtocolVersion() public virtual returns (uint256) {
        return newConfig.oldProtocolVersion;
    }

    /// @notice Generate upgrade cut data
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        require(upgradeConfig.factoryDepsPublished, "Factory deps not published");

        Diamond.FacetCut[] memory facetCutsForDeletion = getFacetCutsForDeletion();

        Diamond.FacetCut[] memory facetCuts;
        facetCuts = formatFacetCuts(getFacetCuts(stateTransition));
        facetCuts = mergeFacets(getFacetCutsForDeletion(), facetCuts);

        VerifierParams memory verifierParams = getVerifierParams();

        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments();

        // Additional force deployments after Gateway
        IL2ContractDeployer.ForceDeployment[]
            memory additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](0);
        // add additional force deployments here
        // additionalForceDeployments[0] = getForceDeployment("L2LegacySharedBridge");

        // TODO: do we update *all* fixed force deployments?

        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = SystemContractsProcessing.mergeForceDeployments(
            baseForceDeployments,
            additionalForceDeployments
        );

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeUpgradeTx(forceDeployments),
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            evmEmulatorHash: config.contracts.evmEmulatorHash,
            verifier: stateTransition.verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });

        if (!stateTransition.isOnGateway) {
            newlyGeneratedData.upgradeCutData = abi.encode(upgradeCutData);
            upgradeConfig.upgradeCutPrepared = true;
        }
    }

    function getForceDeployment(
        string memory contractName
    ) public virtual returns (IL2ContractDeployer.ForceDeployment memory forceDeployment) {
        return
            IL2ContractDeployer.ForceDeployment({
                bytecodeHash: L2ContractHelper.hashL2Bytecode(getCreationCode(contractName)),
                newAddress: getExpectedL2Address(contractName),
                callConstructor: true,
                value: 0,
                input: "" // todo add constructor args here?
            });
    }

    function getEcosystemAdmin() external virtual returns (address) {
        return newConfig.ecosystemAdminAddress;
    }

    function initializeConfig(string memory newConfigPath) internal virtual override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        addresses.stateTransition.bytecodesSupplier = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");

        addresses.bridgehub.bridgehubProxy = toml.readAddress("$.contracts.bridgehub_proxy_address");

        setAddressesBasedOnBridgehub();

        addresses.transparentProxyAdmin = toml.readAddress("$.contracts.transparent_proxy_admin");
        addresses.protocolUpgradeHandlerProxy = toml.readAddress("$.contracts.protocol_upgrade_handler_proxy_address");

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
        newConfig.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");

        newConfig.oldProtocolVersion = toml.readUint("$.old_protocol_version");

        addresses.daAddresses.rollupDAManager = toml.readAddress("$.contracts.rollup_da_manager");
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        config.ownerAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).owner();
        address ctm = IBridgehub(addresses.bridgehub.bridgehubProxy).chainTypeManager(config.eraChainId);
        addresses.stateTransition.chainTypeManagerProxy = ctm;
        // We have to set the diamondProxy address here - as it is used by multiple constructors (for example L1Nullifier etc)
        addresses.stateTransition.diamondProxy = IBridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(
            config.eraChainId
        );
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
        addresses.bridges.l1AssetRouterProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).assetRouter();

        addresses.vaults.l1NativeTokenVaultProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).nativeTokenVault()
        );
        addresses.bridges.l1NullifierProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).L1_NULLIFIER()
        );

        addresses.bridgehub.ctmDeploymentTrackerProxy = address(
            Bridgehub(addresses.bridgehub.bridgehubProxy).l1CtmDeployer()
        );

        addresses.bridgehub.messageRootProxy = address(Bridgehub(addresses.bridgehub.bridgehubProxy).messageRoot());

        addresses.bridges.erc20BridgeProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).legacyBridge()
        );
        newConfig.oldValidatorTimelock = ChainTypeManager(addresses.stateTransition.chainTypeManagerProxy)
            .validatorTimelock();

        newConfig.ecosystemAdminAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).admin();

        address eraDiamondProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(config.eraChainId);
        (addresses.daAddresses.l1RollupDAValidator, ) = GettersFacet(eraDiamondProxy).getDAValidatorPair();
    }

    function generateFixedForceDeploymentsData() internal virtual {
        FixedForceDeploymentsData memory forceDeploymentsData = prepareFixedForceDeploymentsData();

        newlyGeneratedData.fixedForceDeploymentsData = abi.encode(forceDeploymentsData);
        generatedData.forceDeploymentsData = abi.encode(forceDeploymentsData);
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    function getExpectedL2Address(string memory contractName) public virtual returns (address) {
        return
            Utils.getL2AddressViaCreate2Factory(
                bytes32(0), // the same as it is currently in the DeployL1.s.sol. Todo unify.
                L2ContractHelper.hashL2Bytecode(getCreationCode(contractName)),
                hex"" // the same as it is currently in DeployL1.s.sol
            );
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

    function prepareFixedForceDeploymentsData() public view virtual returns (FixedForceDeploymentsData memory data) {
        require(config.ownerAddress != address(0), "owner not set");

        data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: addresses.bridges.l1AssetRouterProxy,
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
            l2SharedBridgeLegacyImpl: address(0),
            // upgradeAddresses.expectedL2Addresses.l2SharedBridgeLegacyImpl,
            l2BridgedStandardERC20Impl: address(0),
            // upgradeAddresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
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
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", addresses.bridgehub.messageRootProxy);
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
        vm.serializeAddress("state_transition", "verifier_fflonk_addr", addresses.stateTransition.verifierFflonk);
        vm.serializeAddress("state_transition", "verifier_plonk_addr", addresses.stateTransition.verifierPlonk);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            addresses.stateTransition.defaultUpgrade
        );

        vm.serializeAddress("bridges", "erc20_bridge_implementation_addr", addresses.bridges.erc20BridgeImplementation);
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", addresses.bridges.l1NullifierProxy);
        vm.serializeAddress("bridges", "l1_nullifier_implementation_addr", addresses.bridges.l1NullifierImplementation);
        vm.serializeAddress(
            "bridges",
            "l1_asset_router_implementation_addr",
            addresses.bridges.l1AssetRouterImplementation
        );
        vm.serializeAddress("bridges", "l1_asset_router_proxy_addr", addresses.bridges.l1AssetRouterProxy);
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
            config.contracts.diamondInitMaxL2GasPerBatch
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_batch_overhead_l1_gas",
            config.contracts.diamondInitBatchOverheadL1Gas
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_max_pubdata_per_batch",
            config.contracts.diamondInitMaxPubdataPerBatch
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_minimal_l2_gas_price",
            config.contracts.diamondInitMinimalL2GasPrice
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_priority_tx_max_pubdata",
            config.contracts.diamondInitPriorityTxMaxPubdata
        );
        vm.serializeUint(
            "contracts_newConfig",
            "diamond_init_pubdata_pricing_mode",
            uint256(config.contracts.diamondInitPubdataPricingMode)
        );
        vm.serializeUint("contracts_newConfig", "priority_tx_max_gas_limit", config.contracts.priorityTxMaxGasLimit);
        vm.serializeBytes32(
            "contracts_newConfig",
            "recursion_circuits_set_vks_hash",
            config.contracts.recursionCircuitsSetVksHash
        );
        vm.serializeBytes32(
            "contracts_newConfig",
            "recursion_leaf_level_vk_hash",
            config.contracts.recursionLeafLevelVkHash
        );
        vm.serializeBytes32(
            "contracts_newConfig",
            "recursion_node_level_vk_hash",
            config.contracts.recursionNodeLevelVkHash
        );

        vm.serializeAddress(
            "contracts_newConfig",
            "expected_rollup_l2_da_validator",
            getExpectedL2Address("RollupL2DAValidator")
        );
        vm.serializeAddress(
            "contracts_newConfig",
            "expected_validium_l2_da_validator",
            getExpectedL2Address("NoDAL2DAValidator")
        );
        vm.serializeBytes("contracts_newConfig", "diamond_cut_data", newlyGeneratedData.diamondCutData);

        vm.serializeBytes(
            "contracts_newConfig",
            "force_deployments_data",
            newlyGeneratedData.fixedForceDeploymentsData
        );

        vm.serializeUint("contracts_newConfig", "new_protocol_version", getNewProtocolVersion());

        vm.serializeUint("contracts_newConfig", "old_protocol_version", newConfig.oldProtocolVersion);

        vm.serializeAddress("contracts_newConfig", "old_validator_timelock", newConfig.oldValidatorTimelock);

        string memory contractsConfig = vm.serializeAddress(
            "contracts_newConfig",
            "l1_legacy_shared_bridge",
            addresses.bridges.l1AssetRouterProxy
        );

        vm.serializeAddress(
            "deployed_addresses",
            "validator_timelock_addr",
            addresses.stateTransition.validatorTimelock
        );
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
            "l1_bytecodes_supplier_addr",
            addresses.stateTransition.bytecodesSupplier
        );
        vm.serializeAddress("deployed_addresses", "native_token_vault_addr", addresses.vaults.l1NativeTokenVaultProxy);
        vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_implementation_addr",
            addresses.vaults.l1NativeTokenVaultImplementation
        );

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
        vm.serializeAddress("deployed_addresses", "l1_transitionary_owner", upgradeAddresses.transitionaryOwner);
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            upgradeAddresses.upgradeTimer
        );

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", config.contracts.create2FactorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_newConfig", contractsConfig);

        vm.serializeBytes("root", "governance_calls", new bytes(0)); // Will be populated later
        vm.serializeAddress("root", "protocol_upgrade_handler_proxy_address", addresses.protocolUpgradeHandlerProxy);

        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        vm.writeToml(toml, outputPath);
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    function publishBytecodes() public virtual {
        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        uint256[] memory factoryDeps = new uint256[](allDeps.length);
        require(factoryDeps.length <= 64, "Too many deps");

        BytecodePublisher.publishBytecodesInBatches(
            BytecodesSupplier(addresses.stateTransition.bytecodesSupplier),
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

    ////////////////////////////// Preparing calls /////////////////////////////////

    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        // Default upgrade is done it 3 stages:
        // 0. Pause migration to/from Gateway
        // 1. Perform upgrade
        // 2. Unpause migration to/from Gateway
        stage0Calls = prepareStage0GovernanceCalls();
        vm.serializeBytes("governance_calls", "governance_stage0_calls", abi.encode(stage0Calls));

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

    /// @notice The zeroth step of upgrade. By default it just stops gateway migrations
    function prepareStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](0);
        calls = mergeCallsArray(allCalls);
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](6);
        //stage 0
        allCalls[0] = preparePauseGatewayMigrationsCall();
        //stage 1
        allCalls[1] = prepareUpgradeProxiesCalls();
        allCalls[2] = prepareNewChainCreationParamsCall();
        allCalls[3] = provideSetNewVersionUpgradeCall();
        allCalls[4] = prepareDAValidatorCall();
        //stage 2
        allCalls[5] = prepareUnpauseGatewayMigrationsCall();
        calls = mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](0);

        calls = mergeCallsArray(allCalls);
    }

    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {
        require(
            addresses.stateTransition.chainTypeManagerProxy != address(0),
            "stateTransitionManagerAddress is zero in newConfig"
        );

        // Just retrieved it from the contract
        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            newlyGeneratedData.upgradeCutData,
            (Diamond.DiamondCutData)
        );
        Call memory ctmCall = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(
                ChainTypeManager.setNewVersionUpgrade,
                (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
            ),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = ctmCall;
    }

    function preparePauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(addresses.bridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: addresses.bridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(IBridgehub.pauseMigration, ())
        });
    }

    function prepareUnpauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(addresses.bridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: addresses.bridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(IBridgehub.unpauseMigration, ())
        });
    }

    function prepareNewChainCreationParamsCall() public virtual returns (Call[] memory calls) {
        require(
            addresses.stateTransition.chainTypeManagerProxy != address(0),
            "stateTransitionManagerAddress is zero in newConfig"
        );
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(
                ChainTypeManager.setChainCreationParams,
                (getChainCreationParams(addresses.stateTransition))
            ),
            value: 0
        });
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public virtual returns (Call[] memory calls) {
        calls = new Call[](5);

        calls[0] = _buildCallProxyUpgrade(
            addresses.stateTransition.chainTypeManagerProxy,
            addresses.stateTransition.chainTypeManagerImplementation
        );

        calls[1] = _buildCallProxyUpgrade(
            addresses.bridgehub.bridgehubProxy,
            addresses.bridgehub.bridgehubImplementation
        );

        // Note, that we do not need to run the initializer
        calls[2] = _buildCallProxyUpgrade(
            addresses.bridges.l1NullifierProxy,
            addresses.bridges.l1NullifierImplementation
        );

        calls[3] = _buildCallProxyUpgrade(
            addresses.bridges.l1AssetRouterProxy,
            addresses.bridges.l1AssetRouterImplementation
        );

        calls[4] = _buildCallProxyUpgrade(
            addresses.vaults.l1NativeTokenVaultProxy,
            addresses.vaults.l1NativeTokenVaultImplementation
        );
    }

    function _buildCallProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        require(addresses.transparentProxyAdmin != address(0), "transparentProxyAdmin not newConfigured");

        call = Call({
            target: addresses.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress)
            ),
            value: 0
        });
    }

    /// @notice Additional calls to newConfigure contracts
    function prepareDAValidatorCall() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.daAddresses.rollupDAManager,
            data: abi.encodeCall(
                RollupDAManager.updateDAPair,
                (addresses.daAddresses.l1RollupDAValidator, getExpectedL2Address("RollupL2DAValidator"), true)
            ),
            value: 0
        });
    }

    function getCreationCode(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "GatewayUpgrade")) {
            return type(GatewayUpgrade).creationCode;
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return type(DefaultUpgrade).creationCode;
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return type(BytecodesSupplier).creationCode;
        } else if (compareStrings(contractName, "TransitionaryOwner")) {
            return type(TransitionaryOwner).creationCode;
        } else if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
            return type(GovernanceUpgradeTimer).creationCode;
        } else if (compareStrings(contractName, "L2LegacySharedBridge")) {
            return L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode();
        } else if (compareStrings(contractName, "L2StandardERC20")) {
            return L2ContractsBytecodesLib.readStandardERC20Bytecode();
        } else if (compareStrings(contractName, "RollupL2DAValidator")) {
            return L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode();
        } else if (compareStrings(contractName, "NoDAL2DAValidator")) {
            return L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode();
        } else {
            return super.getCreationCode(contractName);
        }
    }

    function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "GatewayUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "TransitionaryOwner")) {
            return abi.encode(config.ownerAddress);
        } else if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
            uint256 initialDelay = newConfig.governanceUpgradeTimerInitialDelay;
            uint256 maxAdditionalDelay = 2 weeks;
            return abi.encode(initialDelay, maxAdditionalDelay, config.ownerAddress, newConfig.ecosystemAdminAddress);
        } else if (compareStrings(contractName, "L2LegacySharedBridge")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L2StandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupL2DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "NoDAL2DAValidator")) {
            return abi.encode();
        } else {
            return super.getCreationCalldata(contractName);
        }
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
