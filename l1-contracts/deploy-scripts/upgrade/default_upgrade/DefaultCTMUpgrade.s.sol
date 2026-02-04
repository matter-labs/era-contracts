// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig, StateTransitionDeployedAddresses, StateTransitionDeployedAddresses, ZkChainAddresses} from "../../utils/Types.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ContractsBytecodesLib} from "../../utils/bytecode/ContractsBytecodesLib.sol";
import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {DeployCTMUtils, CTMDeployedAddresses} from "../../ctm/DeployCTMUtils.s.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IValidatorTimelock} from "contracts/state-transition/IValidatorTimelock.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {CTMUpgradeBase} from "./CTMUpgradeBase.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";

/// @notice Script used for default CTM upgrade flow. Should be run after Ecosystem upgrade
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultCTMUpgrade is Script, CTMUpgradeBase {
    using stdToml for string;

    // solhint-disable-next-line gas-struct-packing
    struct UpgradeDeployedAddresses {
        address upgradeTimer;
        address upgradeStageValidator;
    }

    // solhint-disable-next-line gas-struct-packing
    struct AdditionalConfig {
        address ctm;
        uint256 oldProtocolVersion;
        address ecosystemAdminAddress;
        uint256 governanceUpgradeTimerInitialDelay;
    }

    // solhint-disable-next-line gas-struct-packing
    struct GatewayConfig {
        uint256 chainId;
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
        bool fixedForceDeploymentsDataGenerated;
        bool upgradeCutPrepared;
        bool factoryDepsPublished;
        // TODO set it based on version of the BRIDGEHUB before upgrade

        bool ecosystemContractsDeployed;
        string outputPath;
    }

    struct PermanentCTMConfig {
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
        address ctmProxy;
        address bytecodesSupplier;
        address rollupDAManager;
        bool isZKsyncOS;
    }

    // The output of the script
    NewlyGeneratedData internal newlyGeneratedData;
    UpgradeDeployedAddresses internal upgradeAddresses;
    EcosystemUpgradeConfig internal upgradeConfig;

    // Input for the script
    AdditionalConfig internal newConfig;
    GatewayConfig internal gatewayConfig;

    // Discovered addresses
    ZkChainAddresses internal discoveredEraZkChain;
    ZkChainAddresses internal upToDateZkChain;
    L1Bridgehub internal bridgehub;

    uint256[] internal factoryDepsHashes;
    mapping(bytes32 => bool) internal isHashInFactoryDeps;

    function initialize(
        string memory permanentValuesInputPath,
        string memory newConfigPath,
        string memory _outputPath
    ) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);
        permanentValuesInputPath = string.concat(root, permanentValuesInputPath);
        initializeConfigFromFile(permanentValuesInputPath, newConfigPath);
        instantiateCreate2Factory();

        console.log("Initialized config from %s", newConfigPath);
        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    function isHashInFactoryDepsCheck(bytes32 bytecodeHash) internal view virtual override returns (bool) {
        return isHashInFactoryDeps[bytecodeHash];
    }

    function initializeConfig(
        ChainCreationParamsConfig memory chainCreationParams,
        PermanentCTMConfig memory permanentConfig,
        // Optional
        address governance
    ) public {
        _initCreate2FactoryParams(permanentConfig.create2FactoryAddr, permanentConfig.create2FactorySalt);
        config.l1ChainId = block.chainid;
        newConfig.ctm = permanentConfig.ctmProxy;
        ctmAddresses.stateTransition.proxies.bytecodesSupplier = permanentConfig.bytecodesSupplier;
        ctmAddresses.stateTransition.rollupDAManager = permanentConfig.rollupDAManager;
        setAddressesBasedOnCTM();
        config.isZKsyncOS = permanentConfig.isZKsyncOS;
        config.contracts.chainCreationParams = chainCreationParams;

        if (governance != address(0)) {
            config.ownerAddress = governance;
        } else {
            config.ownerAddress = ctmAddresses.admin.governance;
        }
        newConfig.ecosystemAdminAddress = ctmAddresses.admin.governance;
        config.contracts.governanceSecurityCouncilAddress = Governance(payable(ctmAddresses.admin.governance))
            .securityCouncil();
        // config.contracts.governanceMinDelay = Governance(payable(ctmAddresses.admin.governance)).minDelay();
        config.contracts.validatorTimelockExecutionDelay = IValidatorTimelock(
            ctmAddresses.stateTransition.proxies.validatorTimelock
        ).executionDelay();
        (bool ok, bytes memory data) = ctmAddresses.stateTransition.verifiers.verifier.staticcall(
            abi.encodeWithSignature("IS_TESTNET_VERIFIER()")
        );
        config.testnetVerifier = ok;
        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();
    }

    function initializePermanentConfig(
        string memory permanentValuesInputPath
    ) internal virtual returns (PermanentCTMConfig memory permanentConfig) {
        string memory permanentValuesToml = vm.readFile(permanentValuesInputPath);

        (address create2FactoryAddr, bytes32 create2FactorySalt) = getPermanentValues(permanentValuesInputPath);

        address ctm = permanentValuesToml.readAddress("$.ctm_contracts.ctm_proxy_addr");
        address bytecodesSupplier = permanentValuesToml.readAddress("$.ctm_contracts.l1_bytecodes_supplier_addr");
        address rollupDAManager = permanentValuesToml.readAddress("$.ctm_contracts.rollup_da_manager");

        // TODO can we discover it?. Try to get it from the chain
        bool isZKsyncOS;
        if (permanentValuesToml.keyExists("$.is_zk_sync_os")) {
            isZKsyncOS = permanentValuesToml.readBool("$.is_zk_sync_os");
        }

        permanentConfig = PermanentCTMConfig({
            ctmProxy: ctm,
            bytecodesSupplier: bytecodesSupplier,
            rollupDAManager: rollupDAManager,
            isZKsyncOS: isZKsyncOS,
            create2FactoryAddr: create2FactoryAddr,
            create2FactorySalt: create2FactorySalt
        });
    }

    function initializeConfigFromFile(
        string memory permanentValuesInputPath,
        string memory newConfigPath
    ) internal virtual {
        string memory permanentValuesToml = vm.readFile(permanentValuesInputPath);
        string memory toml = vm.readFile(newConfigPath);

        address governance;
        if (toml.keyExists("$.governance")) {
            governance = toml.readAddress("$.governance");
        } else {
            governance = address(0);
        }

        PermanentCTMConfig memory permanentConfig = initializePermanentConfig(permanentValuesInputPath);
        ChainCreationParamsConfig memory chainCreationParams = getChainCreationParamsConfig(
            chainCreationParamsPath(permanentConfig.isZKsyncOS)
        );

        initializeConfig(chainCreationParams, permanentConfig, governance);
    }

    /// @notice Full default upgrade preparation flow
    function prepareCTMUpgrade() public virtual {
        deployNewCTMContracts();
        console.log("CTM contracts are deployed!");
        publishBytecodes();
        console.log("Bytecodes published!");
        // TODO should we deploy state transition diamond facets here again?
        deployStateTransitionDiamondFacets();
        generateUpgradeData();
        console.log("Upgrade data generated!");
    }

    function deployUsedUpgradeContract() internal virtual returns (address) {
        return deploySimpleContract("DefaultUpgrade", false);
    }

    function deployGovernanceUpgradeTimer() internal virtual {
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
    }

    /// @notice Deploy everything that should be deployed
    function deployNewCTMContracts() public virtual {
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();
    }

    function deployUpgradeSpecificContractsL1() internal virtual {
        // Empty by default.
    }

    /// @notice Generate data required for the upgrade
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        // TODO Return the require after getting the version from bridgehub
        //        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Important, this must come after the initializeExpectedL2Addresses
        generateFixedForceDeploymentsData();
        console.log("Generated fixed force deployments data");
        Diamond.DiamondCutData memory diamondCut = getChainCreationDiamondCutData(ctmAddresses.stateTransition);
        // TODO probably don't need to assign it to diamondCutData
        config.contracts.diamondCutData = abi.encode(diamondCut);
        newlyGeneratedData.diamondCutData = config.contracts.diamondCutData;
        console.log("Prepared diamond cut data");
        Diamond.DiamondCutData memory upgradeCutData = generateUpgradeCutDataFromLocalConfig(
            ctmAddresses.stateTransition
        );
        newlyGeneratedData.upgradeCutData = abi.encode(upgradeCutData);
        upgradeConfig.upgradeCutPrepared = true;
        console.log("UpgradeCutGenerated");
        saveOutput(upgradeConfig.outputPath);
    }

    function generateUpgradeCutDataFromLocalConfig(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        upgradeCutData = generateUpgradeCutData(
            stateTransition,
            config.contracts.chainCreationParams,
            config.l1ChainId,
            config.ownerAddress,
            factoryDepsHashes,
            upToDateZkChain.zkChainProxy,
            config.isZKsyncOS
        );
    }

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("UPGRADE_CTM_INPUT"),
            vm.envString("UPGRADE_CTM_OUTPUT")
        );
        prepareCTMUpgrade();

        prepareDefaultGovernanceCalls();
        prepareDefaultCTMAdminCalls();

        prepareDefaultTestUpgradeCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    function setNewProtocolVersion(uint256 _protocolVersion) public virtual {
        config.contracts.chainCreationParams.latestProtocolVersion = _protocolVersion;
    }

    function getNewProtocolVersion() public view virtual returns (uint256) {
        return config.contracts.chainCreationParams.latestProtocolVersion;
    }

    function getOldProtocolVersion() public view virtual returns (uint256) {
        return newConfig.oldProtocolVersion;
    }

    function getBridgehubAdmin() public virtual returns (address admin) {
        return coreAddresses.shared.bridgehubAdmin;
    }

    function getGatewayConfig() public virtual returns (GatewayConfig memory) {
        return gatewayConfig;
    }

    /// @notice This function is meant to only be used in tests
    function prepareCreateNewChainCall(uint256 chainId) public view virtual returns (Call[] memory result) {
        require(coreAddresses.bridgehub.proxies.bridgehub != address(0), "bridgehubProxyAddress is zero in newConfig");

        bytes32 newChainAssetId = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).baseTokenAssetId(
            upToDateZkChain.chainId
        );
        result = new Call[](1);
        result[0] = Call({
            target: coreAddresses.bridgehub.proxies.bridgehub,
            value: 0,
            data: abi.encodeCall(
                IL1Bridgehub.createNewChain,
                (
                    chainId,
                    ctmAddresses.stateTransition.proxies.chainTypeManager,
                    newChainAssetId,
                    5,
                    msg.sender,
                    abi.encode(newlyGeneratedData.diamondCutData, newlyGeneratedData.fixedForceDeploymentsData),
                    new bytes[](0)
                )
            )
        });
    }

    function setAddressesBasedOnCTM() internal virtual {
        address ctm = newConfig.ctm;
        ctmAddresses = AddressIntrospector.getCTMAddresses(ChainTypeManagerBase(ctm));
        bridgehub = L1Bridgehub(ChainTypeManagerBase(ctm).BRIDGE_HUB());
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(address(bridgehub));
        config.ownerAddress = ctmAddresses.admin.governance;
        config.eraChainId = AddressIntrospector.getEraChainId(coreAddresses.bridges.proxies.l1AssetRouter);

        discoveredEraZkChain = AddressIntrospector.getZkChainAddresses(
            IZKChain(bridgehub.getZKChain(config.eraChainId))
        );
        upToDateZkChain = AddressIntrospector.getUptoDateZkChainAddresses(ChainTypeManagerBase(ctm));

        ctmAddresses.daAddresses.l1RollupDAValidator = discoveredEraZkChain.l1DAValidator;
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        newConfig.oldProtocolVersion = ctmProtocolVersion;
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
    }

    function generateFixedForceDeploymentsData() internal virtual {
        FixedForceDeploymentsData memory forceDeploymentsData = prepareFixedForceDeploymentsData();

        newlyGeneratedData.fixedForceDeploymentsData = abi.encode(forceDeploymentsData);
        generatedData.forceDeploymentsData = abi.encode(forceDeploymentsData);
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    function getFullListOfFactoryDependencies() internal virtual returns (bytes[] memory factoryDeps) {
        if (config.isZKsyncOS) {
            // TODO: for now, we do not provide any factory deps for zksync os
            return factoryDeps;
        }

        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies();

        string[] memory additionalForceDeployments = getAdditionalDependenciesNames();

        bytes[] memory additionalDependencies = new bytes[](4 + additionalForceDeployments.length); // Deps after Gateway upgrade
        additionalDependencies[0] = ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacy");
        additionalDependencies[1] = ContractsBytecodesLib.getCreationCode("BridgedStandardERC20");
        additionalDependencies[2] = ContractsBytecodesLib.getCreationCode("DiamondProxy");
        additionalDependencies[3] = ContractsBytecodesLib.getCreationCode("ProxyAdmin");

        for (uint256 i; i < additionalForceDeployments.length; i++) {
            additionalDependencies[4 + i] = ContractsBytecodesLib.getCreationCode(additionalForceDeployments[i]);
        }

        factoryDeps = SystemContractsProcessing.mergeBytesArrays(basicDependencies, additionalDependencies);
        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }

    function prepareFixedForceDeploymentsData() public view virtual returns (FixedForceDeploymentsData memory data) {
        require(config.ownerAddress != address(0), "owner not set");

        data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            eraChainId: config.eraChainId,
            gatewayChainId: config.gatewayChainId,
            l1AssetRouter: coreAddresses.bridges.proxies.l1AssetRouter,
            l2TokenProxyBytecodeHash: getL2BytecodeHash("BeaconProxy"),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress),
            maxNumberOfZKChains: config.contracts.maxNumberOfChains,
            bridgehubBytecodeInfo: abi.encode(getL2BytecodeHash("L2Bridgehub")),
            l2AssetRouterBytecodeInfo: abi.encode(getL2BytecodeHash("L2AssetRouter")),
            l2NtvBytecodeInfo: abi.encode(getL2BytecodeHash("L2NativeTokenVault")),
            messageRootBytecodeInfo: abi.encode(getL2BytecodeHash("L2MessageRoot")),
            chainAssetHandlerBytecodeInfo: abi.encode(getL2BytecodeHash("L2ChainAssetHandler")),
            beaconDeployerInfo: abi.encode(getL2BytecodeHash("UpgradeableBeaconDeployer")),
            interopCenterBytecodeInfo: abi.encode(getL2BytecodeHash("InteropCenter")),
            interopHandlerBytecodeInfo: abi.encode(getL2BytecodeHash("InteropHandler")),
            assetTrackerBytecodeInfo: abi.encode(getL2BytecodeHash("L2AssetTracker")),
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            aliasedChainRegistrationSender: AddressAliasHelper.applyL1ToL2Alias(
                coreAddresses.bridgehub.proxies.chainRegistrationSender
            ),
            // upgradeAddresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            dangerousTestOnlyForcedBeacon: address(0)
        });
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        return getChainCreationFacetCuts(stateTransition);
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    bool skipFactoryDepsCheck = false;

    function setSkipFactoryDepsCheck_TestOnly(bool _skipFactoryDepsCheck) public virtual {
        skipFactoryDepsCheck = _skipFactoryDepsCheck;
    }

    function publishBytecodes() public virtual {
        if (config.isZKsyncOS) {
            // TODO: for now, we do not provide any factory deps for zksync os
            return;
        }

        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        uint256[] memory factoryDeps = new uint256[](allDeps.length);
        require(factoryDeps.length <= 64, "Too many deps");

        BytecodePublisher.publishEraBytecodesInBatches(
            BytecodesSupplier(ctmAddresses.stateTransition.proxies.bytecodesSupplier),
            allDeps
        );

        for (uint256 i = 0; i < allDeps.length; i++) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(allDeps[i]);
            factoryDeps[i] = uint256(bytecodeHash);
            isHashInFactoryDeps[bytecodeHash] = true;
        }

        console.logBytes32(config.contracts.chainCreationParams.bootloaderHash);
        console.log(factoryDeps[0]);
        console.logBytes32(config.contracts.chainCreationParams.defaultAAHash);
        console.log(factoryDeps[1]);
        console.logBytes32(config.contracts.chainCreationParams.evmEmulatorHash);
        console.log(factoryDeps[2]);

        if (!skipFactoryDepsCheck) {
            // Double check for consistency:
            require(
                bytes32(factoryDeps[0]) == config.contracts.chainCreationParams.bootloaderHash,
                "bootloader hash factory dep mismatch"
            );
            require(
                bytes32(factoryDeps[1]) == config.contracts.chainCreationParams.defaultAAHash,
                "default aa hash factory dep mismatch"
            );
            require(
                bytes32(factoryDeps[2]) == config.contracts.chainCreationParams.evmEmulatorHash,
                "EVM emulator hash factory dep mismatch"
            );
        }

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
        // 0. Pause migration to/from Gateway, other stage 0 calls.
        // 1. Perform upgrade
        // 2. Unpause migration to/from Gateway
        stage0Calls = prepareStage0GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(stage0Calls));
        stage1Calls = prepareStage1GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(stage1Calls));
        stage2Calls = prepareStage2GovernanceCalls();

        string memory governanceCallsSerialized = vm.serializeBytes(
            "governance_calls",
            "stage2_calls",
            abi.encode(stage2Calls)
        );

        vm.writeToml(governanceCallsSerialized, upgradeConfig.outputPath, ".governance_calls");
    }

    function prepareDefaultCTMAdminCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);
        allCalls[0] = prepareUpgradeServerNotifierCall();
        calls = UpgradeUtils.mergeCallsArray(allCalls);

        string memory ctmAdminCallsSerialized = vm.serializeBytes(
            "ctm_admin_calls",
            "server_notifier_upgrade",
            abi.encode(calls)
        );

        vm.writeToml(ctmAdminCallsSerialized, upgradeConfig.outputPath, ".ctm_admin_calls");
    }

    function prepareDefaultTestUpgradeCalls() public {
        (Call[] memory testUpgradeChainCall, address ZKChainAdmin) = TESTONLY_prepareTestUpgradeChainCall();
        vm.serializeAddress("test_upgrade_calls", "test_upgrade_chain_caller", ZKChainAdmin);
        vm.serializeBytes("test_upgrade_calls", "test_upgrade_chain", abi.encode(testUpgradeChainCall));
        (Call[] memory testCreateChainCall, address bridgehubAdmin) = TESTONLY_prepareCreateChainCall();
        vm.serializeAddress("test_upgrade_calls", "test_create_chain_caller", bridgehubAdmin);

        string memory testUpgradeCallsSerialized = vm.serializeBytes(
            "test_upgrade_calls",
            "test_create_chain",
            abi.encode(testCreateChainCall)
        );

        vm.writeToml(testUpgradeCallsSerialized, upgradeConfig.outputPath, ".test_upgrade_calls");
    }

    function prepareUpgradeServerNotifierCall() public virtual returns (Call[] memory calls) {
        address serverNotifierProxyAdmin = Utils.getProxyAdminAddress(
            ctmAddresses.stateTransition.proxies.serverNotifier
        );

        Call memory call = Call({
            target: serverNotifierProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(ctmAddresses.stateTransition.proxies.serverNotifier)),
                    ctmAddresses.stateTransition.implementations.serverNotifier
                )
            ),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = call;
    }

    /// @notice The zeroth step of upgrade. By default it just stops gateway migrations
    function prepareStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](2);

        allCalls[0] = prepareVersionSpecificStage0GovernanceCallsL1();
        allCalls[1] = prepareGovernanceUpgradeTimerStartCall();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](7);

        allCalls[0] = prepareGovernanceUpgradeTimerCheckCall();
        allCalls[1] = prepareCheckMigrationsPausedCalls();
        console.log("prepareStage1GovernanceCalls: prepareUpgradeProxiesCalls");
        allCalls[2] = prepareUpgradeCTMCalls();
        console.log("prepareStage1GovernanceCalls: prepareNewChainCreationParamsCall");
        allCalls[3] = prepareNewChainCreationParamsCall();
        console.log("prepareStage1GovernanceCalls: provideSetNewVersionUpgradeCall");
        allCalls[4] = provideSetNewVersionUpgradeCall();
        console.log("prepareStage1GovernanceCalls: prepareDAValidatorCall");
        allCalls[5] = prepareDAValidatorCall();
        console.log("prepareStage1GovernanceCalls: prepareGatewaySpecificStage1GovernanceCalls");
        allCalls[6] = prepareVersionSpecificStage1GovernanceCallsL1();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);

        allCalls[0] = prepareCheckUpgradeIsPresent();
        allCalls[1] = prepareVersionSpecificStage2GovernanceCallsL1();
        allCalls[2] = prepareCheckMigrationsUnpausedCalls();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage0GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage2GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {
        require(
            ctmAddresses.stateTransition.proxies.chainTypeManager != address(0),
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
            target: ctmAddresses.stateTransition.proxies.chainTypeManager,
            data: abi.encodeCall(
                IChainTypeManager.setNewVersionUpgrade,
                (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
            ),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = ctmCall;
    }

    function preparePauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(
            coreAddresses.bridgehub.proxies.chainAssetHandler != address(0),
            "chainAssetHandlerProxy is zero in newConfig"
        );

        result = new Call[](1);
        result[0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandler.pauseMigration, ())
        });
    }

    /// @notice Start the upgrade timer.
    function prepareGovernanceUpgradeTimerStartCall() public virtual returns (Call[] memory calls) {
        require(upgradeAddresses.upgradeTimer != address(0), "upgradeTimer is zero");
        calls = new Call[](1);

        calls[0] = Call({
            target: upgradeAddresses.upgradeTimer,
            data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()),
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

    function prepareNewChainCreationParamsCall() public virtual returns (Call[] memory calls) {
        require(
            ctmAddresses.stateTransition.proxies.chainTypeManager != address(0),
            "stateTransitionManagerAddress is zero in newConfig"
        );
        calls = new Call[](1);

        calls[0] = Call({
            target: ctmAddresses.stateTransition.proxies.chainTypeManager,
            data: abi.encodeCall(
                IChainTypeManager.setChainCreationParams,
                (getChainCreationParams(ctmAddresses.stateTransition))
            ),
            value: 0
        });
    }

    /// @notice Checks to make sure that migrations are paused
    function prepareCheckMigrationsPausedCalls() public virtual returns (Call[] memory calls) {
        require(upgradeAddresses.upgradeStageValidator != address(0), "upgradeStageValidator is zero");
        calls = new Call[](1);

        calls[0] = Call({
            target: upgradeAddresses.upgradeStageValidator,
            // Double checking migrations are paused
            data: abi.encodeCall(UpgradeStageValidator.checkMigrationsPaused, ()),
            value: 0
        });
    }

    /// @notice Checks to make sure that migrations are paused
    function prepareCheckMigrationsUnpausedCalls() public virtual returns (Call[] memory calls) {
        require(upgradeAddresses.upgradeStageValidator != address(0), "upgradeStageValidator is zero");
        calls = new Call[](1);

        calls[0] = Call({
            target: upgradeAddresses.upgradeStageValidator,
            // Double checking migrations are unpaused
            data: abi.encodeCall(UpgradeStageValidator.checkMigrationsUnpaused, ()),
            value: 0
        });
    }

    /// @notice Checks to make sure that the upgrade has happened.
    function prepareCheckUpgradeIsPresent() public virtual returns (Call[] memory calls) {
        require(upgradeAddresses.upgradeStageValidator != address(0), "upgradeStageValidator is zero");
        calls = new Call[](1);

        calls[0] = Call({
            target: upgradeAddresses.upgradeStageValidator,
            // Double checking the presence of the upgrade
            data: abi.encodeCall(UpgradeStageValidator.checkProtocolUpgradePresence, ()),
            value: 0
        });
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeCTMCalls() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = _buildCallProxyUpgrade(
            ctmAddresses.stateTransition.proxies.chainTypeManager,
            ctmAddresses.stateTransition.implementations.chainTypeManager
        );
    }

    function _buildCallProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        require(coreAddresses.shared.transparentProxyAdmin != address(0), "transparentProxyAdmin not newConfigured");

        call = Call({
            target: coreAddresses.shared.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress)
            ),
            value: 0
        });
    }

    /// @notice Additional calls to newConfigure contracts
    function prepareDAValidatorCall() public virtual returns (Call[] memory calls) {
        calls = new Call[](0);

        /// kl todo add back, figure out how we deploy/upgrade the rollup da manager
        // calls[0] = Call({
        //     target: nonDisoverable.rollupDAManager,
        //     data: abi.encodeCall(
        //         RollupDAManager.updateDAPair,
        //         (ctmAddresses.stateTransition.daAddresses.l1RollupDAValidator, getRollupL2DACommitmentScheme(), true)
        //     ),
        //     value: 0
        // });
    }

    function getAddresses() public view override returns (CTMDeployedAddresses memory) {
        return ctmAddresses;
    }

    /// @notice Tests that it is possible to upgrade a chain to the new version
    function TESTONLY_prepareTestUpgradeChainCall() private returns (Call[] memory calls, address admin) {
        address chainDiamondProxyAddress = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).getZKChain(
            upToDateZkChain.chainId
        );
        uint256 oldProtocolVersion = getOldProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = generateUpgradeCutDataFromLocalConfig(
            ctmAddresses.stateTransition
        );

        admin = IZKChain(chainDiamondProxyAddress).getAdmin();

        calls = new Call[](1);
        calls[0] = Call({
            target: chainDiamondProxyAddress,
            data: abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldProtocolVersion, upgradeCutData)),
            value: 0
        });
    }

    /// @notice Tests that it is possible to create a new chain with the new version
    function TESTONLY_prepareCreateChainCall() private returns (Call[] memory calls, address admin) {
        admin = getBridgehubAdmin();
        calls = new Call[](1);
        calls[0] = prepareCreateNewChainCall(555)[0];
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "DiamondProxy")) {
                return type(DiamondProxy).creationCode;
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return type(DefaultUpgrade).creationCode;
            } else if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
                return type(GovernanceUpgradeTimer).creationCode;
            } else if (compareStrings(contractName, "UpgradeStageValidator")) {
                return type(UpgradeStageValidator).creationCode;
            }
        }
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function deployUpgradeStageValidator() internal {
        upgradeAddresses.upgradeStageValidator = deploySimpleContract("UpgradeStageValidator", false);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        require(!isZKBytecode, "ZK bytecodes are not supported in CTM upgrade");
        if (compareStrings(contractName, "UpgradeStageValidator")) {
            return abi.encode(ctmAddresses.stateTransition.proxies.chainTypeManager, getNewProtocolVersion());
        } else if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
            uint256 initialDelay = newConfig.governanceUpgradeTimerInitialDelay;
            uint256 maxAdditionalDelay = 2 weeks;
            return abi.encode(initialDelay, maxAdditionalDelay, config.ownerAddress, newConfig.ecosystemAdminAddress);
        } else {
            return super.getCreationCalldata(contractName, isZKBytecode);
        }
    }

    function saveOutput(string memory outputPath) internal virtual override {
        // Serialize newly deployed state transition addresses
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_implementation_addr",
            ctmAddresses.stateTransition.implementations.chainTypeManager
        );
        vm.serializeAddress("state_transition", "verifier_addr", ctmAddresses.stateTransition.verifiers.verifier);
        vm.serializeAddress("state_transition", "admin_facet_addr", ctmAddresses.stateTransition.facets.adminFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", ctmAddresses.stateTransition.facets.mailboxFacet);
        vm.serializeAddress(
            "state_transition",
            "executor_facet_addr",
            ctmAddresses.stateTransition.facets.executorFacet
        );
        vm.serializeAddress("state_transition", "getters_facet_addr", ctmAddresses.stateTransition.facets.gettersFacet);
        vm.serializeAddress("state_transition", "diamond_init_addr", ctmAddresses.stateTransition.facets.diamondInit);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", ctmAddresses.stateTransition.genesisUpgrade);
        vm.serializeAddress(
            "state_transition",
            "verifier_fflonk_addr",
            ctmAddresses.stateTransition.verifiers.verifierFflonk
        );
        vm.serializeAddress(
            "state_transition",
            "verifier_plonk_addr",
            ctmAddresses.stateTransition.verifiers.verifierPlonk
        );
        vm.serializeAddress(
            "state_transition",
            "validator_timelock_implementation_addr",
            ctmAddresses.stateTransition.implementations.validatorTimelock
        );
        vm.serializeAddress(
            "state_transition",
            "validator_timelock_addr",
            ctmAddresses.stateTransition.proxies.validatorTimelock
        );
        vm.serializeAddress(
            "state_transition",
            "bytecodes_supplier_addr",
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        );
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            ctmAddresses.stateTransition.defaultUpgrade
        );

        // Serialize newly deployed upgrade addresses
        vm.serializeAddress("deployed_addresses", "chain_admin", discoveredEraZkChain.chainAdmin);
        vm.serializeAddress("deployed_addresses", "access_control_restriction_addr", address(0));
        vm.serializeAddress(
            "deployed_addresses",
            "transparent_proxy_admin",
            coreAddresses.shared.transparentProxyAdmin
        );
        vm.serializeAddress("deployed_addresses", "rollup_l1_da_validator_addr", discoveredEraZkChain.l1DAValidator);
        vm.serializeAddress("deployed_addresses", "validium_l1_da_validator_addr", address(0));
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", ctmAddresses.stateTransition.rollupDAManager);
        vm.serializeAddress("deployed_addresses", "upgrade_stage_validator", upgradeAddresses.upgradeStageValidator);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            upgradeAddresses.upgradeTimer
        );

        // Serialize generated upgrade data
        vm.serializeBytes("contracts_newConfig", "diamond_cut_data", newlyGeneratedData.diamondCutData);
        vm.serializeBytes(
            "contracts_newConfig",
            "force_deployments_data",
            newlyGeneratedData.fixedForceDeploymentsData
        );

        // Serialize protocol version info (needed for upgrade)
        vm.serializeUint("contracts_newConfig", "new_protocol_version", getNewProtocolVersion());
        string memory contractsConfig = vm.serializeUint(
            "contracts_newConfig",
            "old_protocol_version",
            newConfig.oldProtocolVersion
        );

        // Serialize root structure
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "state_transition", stateTransition);
        vm.serializeString("root", "contracts_config", contractsConfig);
        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    function saveOutputVersionSpecific() internal virtual {}

    function getCTMAddress() public view returns (address) {
        return newConfig.ctm;
    }
    ////////////////////////////// Misc utils /////////////////////////////////

    // add this to be excluded from coverage report
    function test() internal override {}
}
