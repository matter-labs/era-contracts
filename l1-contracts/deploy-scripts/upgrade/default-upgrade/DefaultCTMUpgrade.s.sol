// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TODO(EVM-1644): LEGACY UPGRADE PROCESS — remove once the registry-driven upgrade process
// (contracts/upgrades/registry: CTMUpgradeExecutor / EcosystemUpgradeExecutor +
// release/transition registries) has fully replaced off-chain governance-calldata generation. Kept for the
// current (v31) upgrade, which still ships hand-composed stage0/1/2 calls.

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig, ZkChainAddresses} from "../../utils/Types.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {CTMDeployedAddresses} from "../../ctm/DeployCTMUtils.s.sol";

import {BytecodePublisher, PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2EcosystemContract} from "../../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../../ecosystem/CoreOnGatewayHelper.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {DefaultL2UpgradeStrategy} from "./DefaultL2UpgradeStrategy.sol";
import {UpgradeHelperLib} from "./UpgradeHelperLib.sol";
import {CTMUpgradeParams} from "./UpgradeParams.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";

/// @notice Script used for default CTM upgrade flow. Should be run after Ecosystem upgrade
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultCTMUpgrade is Script, DefaultL2UpgradeStrategy {
    using stdToml for string;

    uint256 internal constant ERA_TEST_CREATE_CHAIN_ID = 555;
    uint256 internal constant ZKSYNC_OS_TEST_CREATE_CHAIN_ID = 556;

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
        bool hasPreV32IntrospectionOverride;
        bool usePreV32IntrospectionOverride;
    }

    // solhint-disable-next-line gas-struct-packing
    struct GatewayConfig {
        uint256 chainId;
    }

    // solhint-disable-next-line gas-struct-packing
    struct NewlyGeneratedData {
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
        bytes32 create2FactorySalt;
        address ctmProxy;
        address bytecodesSupplier;
        bool isZKsyncOS;
        /// @dev ZK token asset ID, used by `InteropCenter.initL2` for fixed-fee bundles.
        ///      MUST be non-zero — `InteropCenter.initL2` reverts otherwise, which would abort the
        ///      L2 upgrade transaction.
        bytes32 zkTokenAssetId;
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

    PublishFactoryDepsResult internal factoryDepsResult;

    /// @notice Single-call entry point invoked by the protocol-ops CLI's `upgrade-prepare-all`,
    ///         once per CTM proxy (`ICTMUpgradeV31` in `contracts/script-interfaces/IUpgradeV31.sol`).
    function noGovernancePrepare(CTMUpgradeParams memory _params) public virtual {
        // solhint-disable-next-line func-named-parameters
        initializeWithArgs(
            _params.ctmProxy,
            _params.bytecodesSupplier,
            _params.isZKsyncOS,
            _params.rollupDAManager,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath,
            _params.governance,
            _params.zkTokenAssetId
        );
        if (_params.chainRegistrationSender != address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = _params.chainRegistrationSender;
        }
        prepareCTMUpgrade();
        prepareDefaultGovernanceCalls();
        prepareDefaultCTMAdminCalls();

        // Test-only calls (`test_create_chain`, `test_upgrade_chain`) ride the CTM output TOML
        // so protocol-ops can lift them into the merged `ecosystem.toml` for simulator checks.
        prepareDefaultTestUpgradeCalls();
    }

    function initializeWithArgs(
        address ctmProxy,
        address bytecodesSupplier,
        bool isZKsyncOS,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        string memory _outputPath,
        address governance,
        bytes32 zkTokenAssetId
    ) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);
        initializeConfigFromArgs(
            ctmProxy,
            bytecodesSupplier,
            isZKsyncOS,
            rollupDAManager,
            create2FactorySalt,
            newConfigPath,
            governance,
            zkTokenAssetId
        );

        console.log("Initialized config from %s", newConfigPath);
        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    function initializeConfig(
        ChainCreationParamsConfig memory chainCreationParams,
        PermanentCTMConfig memory permanentConfig,
        // Optional
        address governance
    ) public {
        // Only override the salt when explicitly provided (non-zero).
        // When zero, the script falls back to the CREATE2_FACTORY_SALT env var or built-in default.
        if (permanentConfig.create2FactorySalt != bytes32(0)) {
            setCreate2Salt(permanentConfig.create2FactorySalt);
        }
        config.l1ChainId = block.chainid;
        newConfig.ctm = permanentConfig.ctmProxy;

        // The supplier is read off the CTM's `L1_BYTECODES_SUPPLIER()` immutable during discovery, so the
        // permanent-values entry is informational for this path.
        setAddressesBasedOnCTM();
        config.isZKsyncOS = permanentConfig.isZKsyncOS;
        // Must be non-zero: `InteropCenter.initL2` reverts on a zero asset ID. It runs on the genesis path
        // of `performForceDeployedContractsInit` only, so this aborts the genesis of chains created from the
        // release rather than this upgrade — caught here so the misconfiguration surfaces during
        // preparation instead of at a chain's creation.
        require(permanentConfig.zkTokenAssetId != bytes32(0), "zkTokenAssetId must be non-zero");
        config.zkTokenAssetId = permanentConfig.zkTokenAssetId;
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
        // FIXME: need to provide the params as the input for the function, since
        // on mainnet testnetVerifier must be false. Right now the introspection is not available
        // due to the previous version being v29.
        // TODO: restore introspection when L1 state is regenerated with ZKsyncOSTestnetVerifier.IS_TESTNET_VERIFIER
        // (bool ok, bytes memory data) = ctmAddresses.stateTransition.verifiers.verifier.staticcall(
        //     abi.encodeWithSignature("IS_TESTNET_VERIFIER()")
        // );
        // config.testnetVerifier = ok;
        config.testnetVerifier = true;
        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();
    }

    function initializeConfigFromArgs(
        address ctmProxy,
        address bytecodesSupplier,
        bool isZKsyncOS,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        address governance,
        bytes32 zkTokenAssetId
    ) internal virtual {
        string memory toml = vm.readFile(newConfigPath);

        if (toml.keyExists("$.era_chain_id")) {
            config.eraChainId = toml.readUint("$.era_chain_id");
        }

        PermanentCTMConfig memory permanentConfig = PermanentCTMConfig({
            ctmProxy: ctmProxy,
            bytecodesSupplier: bytecodesSupplier,
            isZKsyncOS: isZKsyncOS,
            create2FactorySalt: create2FactorySalt,
            zkTokenAssetId: zkTokenAssetId
        });
        // Set config.isZKsyncOS before getChainCreationParamsConfig.
        config.isZKsyncOS = isZKsyncOS;
        ChainCreationParamsConfig memory chainCreationParams = getChainCreationParamsConfig(
            Utils.genesisConfigPath(isZKsyncOS)
        );

        // Optional explicit target protocol version from the upgrade input. The genesis config
        // (`configs/genesis/*/latest.json`) may still declare the PREVIOUS version while an
        // upgrade to the next one is being prepared, so the upgrade-env preset can pin the
        // packed version the emitted `setNewVersionUpgrade` must carry.
        if (toml.keyExists("$.contracts.latest_protocol_version")) {
            chainCreationParams.latestProtocolVersion = toml.readUint("$.contracts.latest_protocol_version");
        }

        // Optional override for pre-v32 introspection selection
        if (toml.keyExists("$.pre_v32_introspection")) {
            newConfig.hasPreV32IntrospectionOverride = true;
            newConfig.usePreV32IntrospectionOverride = toml.readBool("$.pre_v32_introspection");
        }

        initializeConfig(chainCreationParams, permanentConfig, governance);

        // Read governance upgrade timer initial delay from config
        if (toml.keyExists("$.governance_upgrade_timer_initial_delay")) {
            newConfig.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");
        }

        if (rollupDAManager != address(0)) {
            ctmAddresses.daAddresses.daContracts.rollupDAManager = rollupDAManager;
        }
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
        getFixedForceDeploymentsData();
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
        StateTransitionDeployedAddresses memory _stateTransition
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        upgradeCutData = generateUpgradeCutData(
            _stateTransition,
            config.contracts.chainCreationParams,
            config.l1ChainId,
            config.ownerAddress,
            factoryDepsResult,
            upToDateZkChain.zkChainProxy
        );
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

    function getGovernanceUpgradeTimerInitialDelay() public view virtual returns (uint256) {
        return newConfig.governanceUpgradeTimerInitialDelay;
    }

    function getTestnetVerifier() public view virtual returns (bool) {
        return config.testnetVerifier;
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
                (chainId, ctmAddresses.stateTransition.proxies.chainTypeManager, newChainAssetId, msg.sender)
            )
        });
    }

    function setAddressesBasedOnCTM() internal virtual {
        address ctm = newConfig.ctm;

        // Verify CTM contract exists
        require(ctm.code.length > 0, "CTM contract does not exist at specified address");

        // CTM exists - get bridgehub and determine which introspection to use
        address bridgehubAddr = ChainTypeManagerBase(ctm).BRIDGE_HUB();
        bridgehub = L1Bridgehub(bridgehubAddr);

        bool preV32Ecosystem;
        if (newConfig.hasPreV32IntrospectionOverride) {
            preV32Ecosystem = newConfig.usePreV32IntrospectionOverride;
        } else if (!AddressIntrospector.hasRegisteredChains(bridgehubAddr)) {
            // A chainless ecosystem has no protocol version to inspect. It cannot have been upgraded into
            // existence either, so it was deployed from scratch with the current contracts.
            preV32Ecosystem = false;
        } else {
            preV32Ecosystem = AddressIntrospector.shouldUsePreV32Introspection(bridgehubAddr);
        }

        if (preV32Ecosystem) {
            ctmAddresses = AddressIntrospector.getCTMAddressesV31(ctm, config.isZKsyncOS);
            coreAddresses = AddressIntrospector.getCoreDeployedAddressesV31(bridgehubAddr);
        } else {
            ctmAddresses = AddressIntrospector.getCTMAddresses(ChainTypeManagerBase(ctm));
            coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehubAddr);
        }

        config.ownerAddress = ctmAddresses.admin.governance;
        config.eraChainId = AddressIntrospector.getEraChainId(coreAddresses.bridges.proxies.l1AssetRouter);

        address eraChainAddress = bridgehub.getZKChain(config.eraChainId);
        if (eraChainAddress != address(0)) {
            // ERA chain exists, discover its addresses
            discoveredEraZkChain = AddressIntrospector.getZkChainAddresses(IZKChain(eraChainAddress));
            ctmAddresses.daAddresses.daContracts.rollupSLDAValidator = discoveredEraZkChain.l1DAValidator;
        } else {
            // ERA chain doesn't exist yet (fresh deployment), use up-to-date addresses
            console.log("ERA chain not found in bridgehub, using up-to-date addresses");
        }

        upToDateZkChain = AddressIntrospector.getUptoDateZkChainAddresses(ChainTypeManagerBase(ctm));

        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        newConfig.oldProtocolVersion = ctmProtocolVersion;
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
    }

    function getFixedForceDeploymentsData() internal override returns (FixedForceDeploymentsData memory data) {
        if (upgradeConfig.fixedForceDeploymentsDataGenerated) {
            return abi.decode(generatedData.forceDeploymentsData, (FixedForceDeploymentsData));
        }

        require(config.ownerAddress != address(0), "owner not set");

        data = _buildForceDeploymentsData(config.ownerAddress);
        bytes memory encodedData = abi.encode(data);
        generatedData.forceDeploymentsData = encodedData;
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    bool skipFactoryDepsCheck = false;

    function setSkipFactoryDepsCheck_TestOnly(bool _skipFactoryDepsCheck) public virtual {
        skipFactoryDepsCheck = _skipFactoryDepsCheck;
    }

    function publishBytecodes() public virtual {
        bytes[] memory allDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(
            config.isZKsyncOS,
            getAdditionalFactoryDependencyContracts()
        );
        BytecodesSupplier supplier = BytecodesSupplier(ctmAddresses.stateTransition.proxies.bytecodesSupplier);

        PublishFactoryDepsResult memory result = BytecodePublisher.publishAndProcessFactoryDeps(
            config.isZKsyncOS,
            supplier,
            allDeps
        );

        // Era-only invariant: factoryDepsHashes[0..3] == (bootloader,
        // defaultAA, evmEmulator). ZKsyncOS has none of these concepts —
        // `chainCreationParams.{bootloader,defaultAA,evmEmulator}Hash` are
        // zero and the factoryDepsHashes describe a different, smaller set
        // of contracts, so indexing [1]/[2] would go out of bounds.
        if (!config.isZKsyncOS && result.factoryDepsHashes.length > 0) {
            console.logBytes32(config.contracts.chainCreationParams.bootloaderHash);
            console.log(result.factoryDepsHashes[0]);
            console.logBytes32(config.contracts.chainCreationParams.defaultAAHash);
            console.log(result.factoryDepsHashes[1]);
            console.logBytes32(config.contracts.chainCreationParams.evmEmulatorHash);
            console.log(result.factoryDepsHashes[2]);

            if (!skipFactoryDepsCheck) {
                require(
                    bytes32(result.factoryDepsHashes[0]) == config.contracts.chainCreationParams.bootloaderHash,
                    "bootloader hash factory dep mismatch"
                );
                require(
                    bytes32(result.factoryDepsHashes[1]) == config.contracts.chainCreationParams.defaultAAHash,
                    "default aa hash factory dep mismatch"
                );
                require(
                    bytes32(result.factoryDepsHashes[2]) == config.contracts.chainCreationParams.evmEmulatorHash,
                    "EVM emulator hash factory dep mismatch"
                );
            }
        }

        factoryDepsResult = result;
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

        address chainAdmin = IOwnable(calls[0].target).owner();
        address chainAdminOwner = IOwnable(chainAdmin).owner();
        vm.serializeAddress("ctm_admin_calls", "chain_admin", chainAdmin);
        vm.serializeAddress("ctm_admin_calls", "chain_admin_owner", chainAdminOwner);

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
        uint256 deadline = UpgradeHelperLib.getOldProtocolDeadline();
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

        // Pin the release right after the version bump. A CTM migrated from a pre-registry version
        // has no provenance anchor in storage yet, so the migration setter is emitted first — but
        // only then: it is one-shot by design, so emitting it against an already-anchored CTM would
        // revert the whole bundle.
        address ctmProxy = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address release = ctmAddresses.stateTransition.currentRelease;
        require(release != address(0), "current release not deployed");
        bytes32 releaseCodehash = release.codehash;
        require(releaseCodehash != bytes32(0), "current release has no code");

        // The anchor call is emitted unconditionally. It cannot be decided from a live read: the
        // CTM only gained `releaseCodehash()` in v32, so querying the pre-registry implementation
        // this bundle is about to replace would revert during calldata GENERATION. Emitting it
        // always is safe because the setter is idempotent for an identical value and rejects only
        // a genuine re-point — which would mean the pinned release is not attested anyway.
        calls = new Call[](3);
        calls[0] = ctmCall;
        calls[1] = Call({
            target: ctmProxy,
            data: abi.encodeCall(IChainTypeManager.setReleaseCodehash, (releaseCodehash)),
            value: 0
        });
        calls[2] = Call({
            target: ctmProxy,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (release)),
            value: 0
        });
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
            data: abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
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

    /// @notice Stage-1 slot for pinning new-chain genesis data. Empty from v32 on: the CTM this
    ///         repo upgrades to reads all genesis data from its pinned release and no longer
    ///         implements the legacy `setChainCreationParams`.
    /// @dev `setCurrentRelease` validates `genesisParams` at the CTM's CURRENT protocol version,
    ///      which only becomes the new version once `setNewVersionUpgrade` runs — so the release
    ///      is pinned right AFTER the version bump, in `provideSetNewVersionUpgradeCall`.
    function prepareNewChainCreationParamsCall() public virtual returns (Call[] memory calls) {
        return new Call[](0);
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
        require(ctmAddresses.admin.transparentProxyAdmin != address(0), "ctm transparentProxyAdmin not set");

        call = Call({
            target: ctmAddresses.admin.transparentProxyAdmin,
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
        //         (ctmAddresses.stateTransition.daAddresses.daContracts.rollupSLDAValidator, getRollupL2DACommitmentScheme(), true)
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

        // Each protocol generation exposes a different `upgradeChainFromVersion` on the chain
        // diamond; calling the wrong one hits the DiamondProxy fallback and reverts with "F".
        bytes memory upgradeCallData = UpgradeChainCall.encode(
            chainDiamondProxyAddress,
            oldProtocolVersion,
            upgradeCutData
        );

        calls = new Call[](1);
        calls[0] = Call({target: chainDiamondProxyAddress, data: upgradeCallData, value: 0});
    }

    /// @notice Tests that it is possible to create a new chain with the new version
    function getDefaultTestCreateChainId() public view virtual returns (uint256) {
        return config.isZKsyncOS ? ZKSYNC_OS_TEST_CREATE_CHAIN_ID : ERA_TEST_CREATE_CHAIN_ID;
    }

    function TESTONLY_prepareCreateChainCall() private returns (Call[] memory calls, address admin) {
        admin = getBridgehubAdmin();
        calls = new Call[](1);
        calls[0] = prepareCreateNewChainCall(getDefaultTestCreateChainId())[0];
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
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_proxy",
            ctmAddresses.stateTransition.proxies.chainTypeManager
        );
        // Also save as state_transition_implementation_addr for backwards compatibility with zkstack CLI
        vm.serializeAddress(
            "state_transition",
            "state_transition_implementation_addr",
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
        vm.serializeAddress(
            "state_transition",
            "migrator_facet_addr",
            ctmAddresses.stateTransition.facets.migratorFacet
        );
        vm.serializeAddress(
            "state_transition",
            "committer_facet_addr",
            ctmAddresses.stateTransition.facets.committerFacet
        );
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
        vm.serializeAddress("state_transition", "eip7702_checker_addr", ctmAddresses.admin.eip7702Checker);
        vm.serializeAddress(
            "state_transition",
            "permissionless_validator_addr",
            ctmAddresses.stateTransition.proxies.permissionlessValidator
        );
        if (ctmAddresses.stateTransition.implementations.serverNotifier != address(0)) {
            vm.serializeAddress(
                "state_transition",
                "server_notifier_implementation_addr",
                ctmAddresses.stateTransition.implementations.serverNotifier
            );
        }
        // Introspection reports the engine as zero (nothing on-chain to read it from), so an
        // unassigned engine surviving to serialization means the prepare never deployed one —
        // downstream that zero silently becomes a dead upgrade cut.
        require(ctmAddresses.stateTransition.defaultUpgrade != address(0), "default upgrade not deployed");
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            ctmAddresses.stateTransition.defaultUpgrade
        );

        // Serialize newly deployed upgrade addresses
        vm.serializeAddress("deployed_addresses", "chain_admin", discoveredEraZkChain.chainAdmin);
        vm.serializeAddress("deployed_addresses", "access_control_restriction_addr", address(0));
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin", ctmAddresses.admin.transparentProxyAdmin);
        vm.serializeAddress("deployed_addresses", "rollup_l1_da_validator_addr", discoveredEraZkChain.l1DAValidator);
        vm.serializeAddress("deployed_addresses", "validium_l1_da_validator_addr", address(0));
        vm.serializeAddress(
            "deployed_addresses",
            "l1_rollup_da_manager",
            ctmAddresses.daAddresses.daContracts.rollupDAManager
        );
        vm.serializeAddress("deployed_addresses", "upgrade_stage_validator", upgradeAddresses.upgradeStageValidator);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            upgradeAddresses.upgradeTimer
        );

        vm.serializeAddress("admin", "timer_governance_addr", config.ownerAddress);
        string memory admin = vm.serializeAddress("admin", "ecosystem_admin_addr", newConfig.ecosystemAdminAddress);

        // Serialize generated upgrade data
        vm.serializeBytes("contracts_newConfig", "diamond_cut_data", newlyGeneratedData.diamondCutData);
        vm.serializeBytes("contracts_newConfig", "force_deployments_data", generatedData.forceDeploymentsData);

        // Serialize protocol version info (needed for upgrade)
        vm.serializeUint("contracts_newConfig", "new_protocol_version", getNewProtocolVersion());
        vm.serializeUint(
            "contracts_newConfig",
            "governance_upgrade_timer_initial_delay",
            newConfig.governanceUpgradeTimerInitialDelay
        );
        vm.serializeBool("contracts_newConfig", "is_testnet", config.testnetVerifier);
        string memory contractsConfig = vm.serializeUint(
            "contracts_newConfig",
            "old_protocol_version",
            newConfig.oldProtocolVersion
        );

        // Serialize root structure
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "state_transition", stateTransition);
        vm.serializeString("root", "contracts_config", contractsConfig);
        vm.serializeString("root", "admin", admin);
        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    function saveOutputVersionSpecific() internal virtual {}

    function getCTMAddress() public view returns (address) {
        return newConfig.ctm;
    }

    function getChainUpgradeDiamondCutData() public view returns (bytes memory) {
        require(upgradeConfig.upgradeCutPrepared, "upgrade cut data not prepared");
        return newlyGeneratedData.upgradeCutData;
    }

    /// @dev Test-only: inject pre-computed upgrade cut data to avoid recomputing (memory optimization).
    function setChainUpgradeDiamondCutData_TestOnly(bytes memory _data) public {
        newlyGeneratedData.upgradeCutData = _data;
        upgradeConfig.upgradeCutPrepared = true;
    }

    /// @dev Test-only: inject pre-computed fixed force deployments data.
    function setFixedForceDeploymentsData_TestOnly(bytes memory _data) public {
        generatedData.forceDeploymentsData = _data;
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    /// @notice Returns the encoded FixedForceDeploymentsData bytes.
    function getEncodedFixedForceDeploymentsData() public view returns (bytes memory) {
        require(upgradeConfig.fixedForceDeploymentsDataGenerated, "force deployments data not generated");
        return generatedData.forceDeploymentsData;
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    // add this to be excluded from coverage report
    function test() internal override {}
}
