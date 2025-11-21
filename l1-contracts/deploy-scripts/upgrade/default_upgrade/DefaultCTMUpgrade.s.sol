// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ContractsBytecodesLib} from "../../utils/bytecode/ContractsBytecodesLib.sol";
import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {DeployCTMUtils, DeployedAddresses} from "../../ctm/DeployCTMUtils.s.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IChainAssetHandler} from "contracts/bridgehub/IChainAssetHandler.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BridgehubDeployedAddresses, BridgesDeployedAddresses} from "../../ecosystem/DeployL1CoreUtils.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";

/// @notice Script used for default upgrade flow
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultCTMUpgrade is Script, DeployCTMUtils {
    using stdToml for string;

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // solhint-disable-next-line gas-struct-packing
    struct UpgradeDeployedAddresses {
        ExpectedL2Addresses expectedL2Addresses;
        address transitionaryOwner;
        address upgradeTimer;
        address bytecodesSupplier;
        address l2WrappedBaseTokenStore;
        address upgradeStageValidator;
        address nativeTokenVaultImplementation;
    }

    struct ExpectedL2Addresses {
        address expectedRollupL2DAValidator;
        address expectedValidiumL2DAValidator;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
    }

    // solhint-disable-next-line gas-struct-packing
    struct AdditionalConfig {
        address ctm;
        // This is the address of the ecosystem admin.
        // Note, that it is not the owner, but rather the address that is responsible
        // for facilitating partially trusted, but not critical tasks.
        address ecosystemAdminAddress;
        uint256 oldProtocolVersion;
        address oldValidatorTimelock;
        uint256 priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Gateway {
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
        bool ecosystemContractsDeployed;
        string outputPath;
    }

    AdditionalConfig internal newConfig;
    Gateway internal gatewayConfig;
    NewlyGeneratedData internal newlyGeneratedData;
    UpgradeDeployedAddresses internal upgradeAddresses;
    BridgehubDeployedAddresses internal bridgehubAddresses;
    BridgesDeployedAddresses internal bridges;
    AddressIntrospector.CTMAddresses internal discoveredCTM;
    AddressIntrospector.ZkChainAddresses internal discoveredEraZkChain;
    AddressIntrospector.NonDisoverable internal nonDisoverable;
    L1Bridgehub internal bridgehub;

    uint256[] internal factoryDepsHashes;
    mapping(bytes32 => bool) internal isHashInFactoryDeps;

    EcosystemUpgradeConfig internal upgradeConfig;

    function initialize(string memory newConfigPath, string memory _outputPath) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);

        initializeConfig(newConfigPath);

        console.log("Initialized config from %s", newConfigPath);
        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    /// @notice Full default upgrade preparation flow
    function prepareEcosystemUpgrade() public virtual {
        deployNewEcosystemContractsL1();
        console.log("Ecosystem contracts are deployed!");
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

    /// @notice Deploy everything that should be deployed
    function deployNewEcosystemContractsL1() public virtual {}

    function deployUpgradeSpecificContractsL1() internal virtual {
        // Empty by default.
    }

    /// @notice Encode calldata that will be passed to `_postUpgrade`
    /// in the on‑chain contract. Override in concrete upgrades.
    function encodePostUpgradeCalldata(
        StateTransitionDeployedAddresses memory
    ) internal virtual returns (bytes memory) {
        return new bytes(0);
    }

    /// @notice Generate data required for the upgrade
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Important, this must come after the initializeExpectedL2Addresses
        generateFixedForceDeploymentsData();
        console.log("Generated fixed force deployments data");
        getChainCreationDiamondCutData(addresses.stateTransition);
        newlyGeneratedData.diamondCutData = config.contracts.diamondCutData;
        console.log("Prepared diamond cut data");
        generateUpgradeCutData(addresses.stateTransition);
        upgradeConfig.upgradeCutPrepared = true;
        console.log("UpgradeCutGenerated");
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice E2e upgrade generation
    function run() public virtual {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
        prepareDefaultEcosystemAdminCalls();

        prepareDefaultTestUpgradeCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        address diamondProxy = discoveredEraZkChain.zkChainProxy;
        return UpgradeUtils.getFacetCutsForDeletion(IZKChain(diamondProxy));
    }

    /// @notice Build L1 -> L2 upgrade tx
    function _composeUpgradeTx(
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments
    ) internal virtual returns (L2CanonicalTransaction memory transaction) {
        return
            UpgradeUtils.composeUpgradeTx(
                forceDeployments,
                isHashInFactoryDeps,
                factoryDepsHashes,
                UpgradeUtils.getProtocolUpgradeNonce(getNewProtocolVersion()),
                config.isZKsyncOS
            );
    }

    function getNewProtocolVersion() public virtual returns (uint256) {
        return config.contracts.chainCreationParams.latestProtocolVersion;
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
        facetCuts = getUpgradeAddedFacetCuts(stateTransition);
        facetCuts = UpgradeUtils.mergeFacets(facetCutsForDeletion, facetCuts);

        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade(stateTransition);

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });

        newlyGeneratedData.upgradeCutData = abi.encode(upgradeCutData);
    }

    function getProposedPatchUpgrade(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        VerifierParams memory verifierParams = getVerifierParams();
        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: UpgradeUtils.emptyUpgradeTx(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            verifier: stateTransition.verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        VerifierParams memory verifierParams = getVerifierParams();

        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments(config.l1ChainId, config.ownerAddress);

        // Additional force deployments after Gateway
        IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments = getAdditionalForceDeployments();

        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = SystemContractsProcessing.mergeForceDeployments(
            baseForceDeployments,
            additionalForceDeployments
        );

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeUpgradeTx(forceDeployments),
            bootloaderHash: config.contracts.chainCreationParams.bootloaderHash,
            defaultAccountHash: config.contracts.chainCreationParams.defaultAAHash,
            evmEmulatorHash: config.contracts.chainCreationParams.evmEmulatorHash,
            verifier: stateTransition.verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });
    }

    function getForceDeployment(
        string memory contractName
    ) public virtual returns (IL2ContractDeployer.ForceDeployment memory forceDeployment) {
        return
            IL2ContractDeployer.ForceDeployment({
                bytecodeHash: getL2BytecodeHash(contractName),
                newAddress: getExpectedL2Address(contractName),
                callConstructor: false,
                value: 0,
                input: ""
            });
    }

    function getAdditionalForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments)
    {
        string[] memory forceDeploymentNames = getForceDeploymentNames();
        additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](forceDeploymentNames.length);
        for (uint256 i; i < forceDeploymentNames.length; i++) {
            additionalForceDeployments[i] = getForceDeployment(forceDeploymentNames[i]);
        }
        return additionalForceDeployments;
    }

    function getAdditionalDependenciesNames() internal virtual returns (string[] memory forceDeploymentNames) {
        return new string[](0);
    }

    function getForceDeploymentNames() internal virtual returns (string[] memory forceDeploymentNames) {
        forceDeploymentNames = new string[](0);
    }

    function getEcosystemAdmin() external virtual returns (address) {
        return newConfig.ecosystemAdminAddress;
    }

    function initializeConfig(string memory newConfigPath) internal virtual override {
        string memory toml = vm.readFile(newConfigPath);

        bytes32 create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        address create2FactoryAddr;
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        _initCreate2FactoryParams(create2FactoryAddr, create2FactorySalt);

        newConfig.ctm = toml.readAddress("$.contracts.ctm_proxy_address");
        // Can we safely get it from the CTM? is it always exists even for zksync os ?
        config.eraChainId = toml.readUint("$.era_chain_id");

        nonDisoverable.bytecodesSupplier = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");
        nonDisoverable.rollupDAManager = toml.readAddress("$.contracts.rollup_da_manager");
        bridgehub = L1Bridgehub(toml.readAddress("$.contracts.bridgehub_proxy_address"));
        setAddressesBasedOnBridgehub();

        config.l1ChainId = block.chainid;
        config.ownerAddress = discoveredBridgehub.governance;

        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();

        // TODO IS IT TRUE?
        config.ownerAddress = discoveredCTM.governance;
        (bool ok, bytes memory data) = discoveredEraZkChain.verifier.staticcall(
            abi.encodeWithSignature("isTestnetVerifier()")
        );
        config.testnetVerifier = ok;
        // TODO can we discover it?
        if (toml.keyExists("$.is_zk_sync_os")) {
            config.isZKsyncOS = toml.readBool("$.is_zk_sync_os");
        }

        config.contracts.governanceSecurityCouncilAddress = Governance(discoveredCTM.governance).securityCouncil();
        config.contracts.governanceMinDelay = Governance(discoveredCTM.governance).minDelay();
        config.contracts.validatorTimelockExecutionDelay = IValidatorTimelock(discoveredCTM.validatorTimelockPostV29)
            .executionDelay();

        // Default values for initializing the chain. They are part of the chain creation params,
        // meanwhile they are not saved anywhere
        config.contracts.chainCreationParams.latestProtocolVersion = toml.readUint(
            "$.contracts.latest_protocol_version"
        );
        config.contracts.chainCreationParams.diamondInitPubdataPricingMode = PubdataPricingMode(
            toml.readUint("$.contracts.diamond_init_pubdata_pricing_mode")
        );
        config.contracts.chainCreationParams.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.contracts.diamond_init_batch_overhead_l1_gas"
        );
        config.contracts.chainCreationParams.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_pubdata_per_batch"
        );
        config.contracts.chainCreationParams.diamondInitMaxL2GasPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_l2_gas_per_batch"
        );
        config.contracts.chainCreationParams.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.contracts.diamond_init_priority_tx_max_pubdata"
        );
        config.contracts.chainCreationParams.diamondInitMinimalL2GasPrice = toml.readUint(
            "$.contracts.diamond_init_minimal_l2_gas_price"
        );

        // Protocol specific params for the entire CTM
        config.contracts.chainCreationParams.genesisRoot = toml.readBytes32("$.contracts.genesis_root");
        config.contracts.chainCreationParams.genesisRollupLeafIndex = toml.readUint(
            "$.contracts.genesis_rollup_leaf_index"
        );
        config.contracts.chainCreationParams.genesisBatchCommitment = toml.readBytes32(
            "$.contracts.genesis_batch_commitment"
        );
        config.contracts.chainCreationParams.defaultAAHash = toml.readBytes32("$.contracts.default_aa_hash");
        config.contracts.chainCreationParams.bootloaderHash = toml.readBytes32("$.contracts.bootloader_hash");
        config.contracts.chainCreationParams.evmEmulatorHash = toml.readBytes32("$.contracts.evm_emulator_hash");
    }

    function getBridgehubAdmin() public virtual returns (address admin) {
        admin = discoveredBridgehub.admin;
    }

    /// @notice This function is meant to only be used in tests
    function prepareCreateNewChainCall(uint256 chainId) public view virtual returns (Call[] memory result) {
        require(discoveredBridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");

        bytes32 newChainAssetId = L1Bridgehub(discoveredBridgehub.bridgehubProxy).baseTokenAssetId(
            gatewayConfig.chainId
        );
        result = new Call[](1);
        result[0] = Call({
            target: discoveredBridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(
                IL1Bridgehub.createNewChain,
                (
                    chainId,
                    discoveredCTM.ctmProxy,
                    newChainAssetId,
                    5,
                    msg.sender,
                    abi.encode(newlyGeneratedData.diamondCutData, newlyGeneratedData.fixedForceDeploymentsData),
                    new bytes[](0)
                )
            )
        });
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        discoveredBridgehub = AddressIntrospector.getBridgehubAddresses(bridgehub);
        config.ownerAddress = discoveredBridgehub.governance;
        address ctm = newConfig.ctm;
        discoveredCTM = AddressIntrospector.getCTMAddresses(ChainTypeManagerBase(ctm));
        discoveredEraZkChain = AddressIntrospector.getZkChainAddresses(
            IZKChain(bridgehub.getZKChain(config.eraChainId))
        );

        addresses.daAddresses.l1RollupDAValidator = discoveredEraZkChain.l1DAValidator;
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        newConfig.oldProtocolVersion = ctmProtocolVersion;
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
        bridges.l1AssetRouterProxy = discoveredBridgehub.assetRouter;

        bridges.l1NullifierProxy = address(L1AssetRouter(bridges.l1AssetRouterProxy).L1_NULLIFIER());
        bridges.erc20BridgeProxy = address(L1AssetRouter(bridges.l1AssetRouterProxy).legacyBridge());

        newConfig.oldValidatorTimelock = discoveredCTM.validatorTimelockPostV29;
        newConfig.ecosystemAdminAddress = discoveredBridgehub.admin;
    }

    function generateFixedForceDeploymentsData() internal virtual {
        FixedForceDeploymentsData memory forceDeploymentsData = prepareFixedForceDeploymentsData();

        newlyGeneratedData.fixedForceDeploymentsData = abi.encode(forceDeploymentsData);
        generatedData.forceDeploymentsData = abi.encode(forceDeploymentsData);
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    function getExpectedL2Address(string memory contractName) public virtual returns (address) {
        string[2] memory expectedCreate2Deployed = ["RollupL2DAValidator", "NoDAL2DAValidator"];

        for (uint256 i; i < expectedCreate2Deployed.length; i++) {
            if (compareStrings(contractName, expectedCreate2Deployed[i])) {
                return Utils.getL2AddressViaCreate2Factory(bytes32(0), getL2BytecodeHash(contractName), hex"");
            }
        }

        revert(string.concat("No expected L2 address for: ", contractName));
    }

    function getFullListOfFactoryDependencies() internal virtual returns (bytes[] memory factoryDeps) {
        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies();

        string[] memory additionalForceDeployments = getAdditionalDependenciesNames();

        bytes[] memory additionalDependencies = new bytes[](7 + additionalForceDeployments.length); // Deps after Gateway upgrade
        additionalDependencies[0] = ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacy");
        additionalDependencies[1] = ContractsBytecodesLib.getCreationCode("BridgedStandardERC20");
        additionalDependencies[2] = ContractsBytecodesLib.getCreationCode("RollupL2DAValidator");
        // TODO(refactor): do we need this?
        additionalDependencies[4] = ContractsBytecodesLib.getCreationCode("DiamondProxy");
        additionalDependencies[5] = ContractsBytecodesLib.getCreationCode("L2V29Upgrade");
        additionalDependencies[6] = ContractsBytecodesLib.getCreationCode("ProxyAdmin");

        for (uint256 i; i < additionalForceDeployments.length; i++) {
            additionalDependencies[6 + i] = ContractsBytecodesLib.getCreationCode(additionalForceDeployments[i]);
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
            l1AssetRouter: discoveredBridgehub.assetRouter,
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
            assetTrackerBytecodeInfo: abi.encode(getL2BytecodeHash("AssetTracker")),
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            aliasedChainRegistrationSender: AddressAliasHelper.applyL1ToL2Alias(
                discoveredBridgehub.chainRegistrationSenderProxy
            ),
            // upgradeAddresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            dangerousTestOnlyForcedBeacon: address(0)
        });
    }

    function saveOutputVersionSpecific() internal virtual {}

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        return getChainCreationFacetCuts(stateTransition);
    }

    function saveOutput(string memory outputPath) internal virtual {
        // Serialize newly deployed state transition addresses
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
        vm.serializeAddress(
            "state_transition",
            "validator_timelock_implementation_addr",
            addresses.stateTransition.validatorTimelockImplementation
        );
        vm.serializeAddress("state_transition", "validator_timelock_addr", addresses.stateTransition.validatorTimelock);
        vm.serializeAddress("state_transition", "bytecodes_supplier_addr", addresses.stateTransition.bytecodesSupplier);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            addresses.stateTransition.defaultUpgrade
        );

        // Serialize newly deployed upgrade addresses
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin", addresses.transparentProxyAdmin);
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
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);
        vm.serializeAddress("deployed_addresses", "l1_transitionary_owner", upgradeAddresses.transitionaryOwner);
        vm.serializeAddress("deployed_addresses", "upgrade_stage_validator", upgradeAddresses.upgradeStageValidator);
        vm.serializeAddress(
            "deployed_addresses",
            "l2_wrapped_base_token_store_addr",
            upgradeAddresses.l2WrappedBaseTokenStore
        );
        vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_implementation_addr",
            upgradeAddresses.nativeTokenVaultImplementation
        );
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
        vm.serializeUint("contracts_newConfig", "old_protocol_version", newConfig.oldProtocolVersion);
        vm.serializeAddress("contracts_newConfig", "old_validator_timelock", newConfig.oldValidatorTimelock);

        // Serialize expected L2 addresses (computed during execution)
        vm.serializeAddress(
            "contracts_newConfig",
            "expected_rollup_l2_da_validator",
            getExpectedL2Address("RollupL2DAValidator")
        );
        string memory contractsConfig = vm.serializeAddress(
            "contracts_newConfig",
            "expected_validium_l2_da_validator",
            getExpectedL2Address("NoDAL2DAValidator")
        );

        // Serialize root structure
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "state_transition", stateTransition);
        vm.serializeString("root", "contracts_config", contractsConfig);
        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    function publishBytecodes() public virtual {
        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        uint256[] memory factoryDeps = new uint256[](allDeps.length);
        require(factoryDeps.length <= 64, "Too many deps");

        BytecodePublisher.publishBytecodesInBatches(BytecodesSupplier(nonDisoverable.bytecodesSupplier), allDeps);

        for (uint256 i = 0; i < allDeps.length; i++) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(allDeps[i]);
            factoryDeps[i] = uint256(bytecodeHash);
            isHashInFactoryDeps[bytecodeHash] = true;
        }

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
        // 1. Perform upgrade
        // 2. Unpause migration to/from Gateway
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

    function prepareDefaultEcosystemAdminCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);
        allCalls[0] = prepareUpgradeServerNotifierCall();
        calls = UpgradeUtils.mergeCallsArray(allCalls);

        string memory ecosystemAdminCallsSerialized = vm.serializeBytes(
            "ecosystem_admin_calls",
            "server_notifier_upgrade",
            abi.encode(calls)
        );

        vm.writeToml(ecosystemAdminCallsSerialized, upgradeConfig.outputPath, ".ecosystem_admin_calls");
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
        address serverNotifierProxyAdmin = address(uint160(uint256(vm.load(discoveredCTM.serverNotifier, ADMIN_SLOT))));

        Call memory call = Call({
            target: serverNotifierProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(discoveredCTM.serverNotifier)),
                    addresses.stateTransition.serverNotifierImplementation
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
        Call[][] memory allCalls = new Call[][](8);

        allCalls[0] = prepareCheckMigrationsPausedCalls();
        console.log("prepareStage1GovernanceCalls: prepareUpgradeProxiesCalls");
        allCalls[1] = prepareUpgradeCTMCalls();
        console.log("prepareStage1GovernanceCalls: prepareNewChainCreationParamsCall");
        allCalls[2] = prepareNewChainCreationParamsCall();
        console.log("prepareStage1GovernanceCalls: provideSetNewVersionUpgradeCall");
        allCalls[3] = provideSetNewVersionUpgradeCall();
        console.log("prepareStage1GovernanceCalls: prepareDAValidatorCall");
        allCalls[4] = prepareDAValidatorCall();
        console.log("prepareStage1GovernanceCalls: prepareGatewaySpecificStage1GovernanceCalls");
        allCalls[5] = prepareVersionSpecificStage1GovernanceCallsL1();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](5);

        allCalls[0] = prepareCheckUpgradeIsPresent();
        allCalls[1] = prepareUnpauseGatewayMigrationsCall();
        allCalls[2] = prepareVersionSpecificStage2GovernanceCallsL1();
        allCalls[4] = prepareCheckMigrationsUnpausedCalls();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage0GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage0GovernanceCallsGW(
        uint256 priorityTxsL2GasLimit,
        uint256 maxExpectedL1GasPrice
    ) public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage1GovernanceCallsGW(
        uint256 priorityTxsL2GasLimit,
        uint256 maxExpectedL1GasPrice
    ) public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage2GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage2GovernanceCallsGW(
        uint256 priorityTxsL2GasLimit,
        uint256 maxExpectedL1GasPrice
    ) public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {
        require(discoveredCTM.ctmProxy != address(0), "stateTransitionManagerAddress is zero in newConfig");

        // Just retrieved it from the contract
        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = UpgradeUtils.getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            newlyGeneratedData.upgradeCutData,
            (Diamond.DiamondCutData)
        );
        Call memory ctmCall = Call({
            target: discoveredCTM.ctmProxy,
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
        require(discoveredBridgehub.chainAssetHandler != address(0), "chainAssetHandlerProxy is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: discoveredBridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(IChainAssetHandler.pauseMigration, ())
        });
    }

    function prepareUnpauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(discoveredBridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: discoveredBridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(IChainAssetHandler.unpauseMigration, ())
        });
    }

    // TODO Ecosystem v29 depends on it
    function _prepareL1ToGatewayCall(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        uint256 l1GasPrice,
        address dstAddress
    ) internal view returns (Call[] memory calls) {
        require(gatewayConfig.chainId != 0, "Chain id of gateway is zero in newConfig");

        require(discoveredBridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");
        require(discoveredBridgehub.assetRouter != address(0), "l1AssetRouterProxyAddress is zero in newConfig");

        calls = Utils.prepareGovernanceL1L2DirectTransaction(
            l1GasPrice,
            l2Calldata,
            l2GasLimit,
            new bytes[](0),
            dstAddress,
            gatewayConfig.chainId,
            discoveredBridgehub.bridgehubProxy,
            discoveredBridgehub.assetRouter,
            msg.sender
        );
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
        require(discoveredCTM.ctmProxy != address(0), "stateTransitionManagerAddress is zero in newConfig");
        calls = new Call[](1);

        calls[0] = Call({
            target: discoveredCTM.ctmProxy,
            data: abi.encodeCall(
                IChainTypeManager.setChainCreationParams,
                (getChainCreationParams(addresses.stateTransition))
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
            discoveredCTM.ctmProxy,
            addresses.stateTransition.chainTypeManagerImplementation
        );
    }

    function _buildCallProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        require(discoveredBridgehub.transparentProxyAdmin != address(0), "transparentProxyAdmin not newConfigured");

        call = Call({
            target: discoveredBridgehub.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress)
            ),
            value: 0
        });
    }

    function _buildCallBeaconProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        call = Call({
            target: proxyAddress,
            data: abi.encodeCall(UpgradeableBeacon.upgradeTo, (newImplementationAddress)),
            value: 0
        });
    }

    /// @notice Additional calls to newConfigure contracts
    function prepareDAValidatorCall() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = Call({
            target: nonDisoverable.rollupDAManager,
            data: abi.encodeCall(
                RollupDAManager.updateDAPair,
                (addresses.daAddresses.l1RollupDAValidator, getRollupL2DACommitmentScheme(), true)
            ),
            value: 0
        });
    }

    function getAddresses() public view returns (DeployedAddresses memory) {
        return addresses;
    }

    /// @notice Tests that it is possible to upgrade a chain to the new version
    function TESTONLY_prepareTestUpgradeChainCall() private returns (Call[] memory calls, address admin) {
        address chainDiamondProxyAddress = L1Bridgehub(discoveredBridgehub.bridgehubProxy).getZKChain(
            gatewayConfig.chainId
        );
        uint256 oldProtocolVersion = getOldProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = generateUpgradeCutData(getAddresses().stateTransition);

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
        require(!isZKBytecode, "ZK bytecodes are not supported in CTM upgrade");
        if (compareStrings(contractName, "DiamondProxy")) {
            return type(DiamondProxy).creationCode;
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return type(DefaultUpgrade).creationCode;
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return type(BytecodesSupplier).creationCode;
        } else if (compareStrings(contractName, "TransitionaryOwner")) {
            return type(TransitionaryOwner).creationCode;
        } else if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
            return type(GovernanceUpgradeTimer).creationCode;
        } else if (compareStrings(contractName, "L2StandardERC20")) {
            return ContractsBytecodesLib.getCreationCode("BridgedStandardERC20");
        } else if (compareStrings(contractName, "RollupL2DAValidator")) {
            return ContractsBytecodesLib.getCreationCode("RollupL2DAValidator");
        } else if (compareStrings(contractName, "NoDAL2DAValidator")) {
            return ContractsBytecodesLib.getCreationCode("ValidiumL2DAValidator");
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return type(ValidatorTimelock).creationCode;
        } else {
            return super.getCreationCode(contractName, isZKBytecode);
        }
    }

    function deployUpgradeStageValidator() internal {
        upgradeAddresses.upgradeStageValidator = deploySimpleContract("UpgradeStageValidator", false);
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    // add this to be excluded from coverage report
    function test() internal override {}
}
