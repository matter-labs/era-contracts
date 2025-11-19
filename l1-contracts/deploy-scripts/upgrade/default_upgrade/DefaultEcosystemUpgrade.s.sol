// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {L2_BRIDGEHUB_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ContractsBytecodesLib} from "../../utils/bytecode/ContractsBytecodesLib.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {DeployL1CoreUtils, DeployedAddresses} from "../../ecosystem/DeployL1CoreUtils.s.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {IChainAssetHandler} from "contracts/bridgehub/IChainAssetHandler.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {BridgehubDeployedAddresses, L1NativeTokenVaultAddresses, BridgesDeployedAddresses} from "../../ecosystem/DeployL1CoreUtils.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";

/// @notice Script used for default upgrade flow
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultEcosystemUpgrade is Script, DeployL1CoreUtils {
    using stdToml for string;

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    uint256 internal constant MAX_ADDITIONAL_DELAY = 2 weeks;

    // solhint-disable-next-line gas-struct-packing
    struct UpgradeDeployedAddresses {
        address transitionaryOwner;
        address bridgehubImplementationAddress;
    }

    // solhint-disable-next-line gas-struct-packing
    struct AdditionalConfig {
        // This is the address of the ecosystem admin.
        // Note, that it is not the owner, but rather the address that is responsible
        // for facilitating partially trusted, but not critical tasks.
        address ecosystemAdminAddress;
        uint256 governanceUpgradeTimerInitialDelay;
        uint256 oldProtocolVersion;
        address oldValidatorTimelock;
        uint256 priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Gateway {
        StateTransitionDeployedAddresses gatewayStateTransition;
        bytes facetCutsData;
        bytes additionalForceDeployments;
        uint256 chainId;
        address baseToken;
        bytes upgradeCutData;
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
    BridgehubDeployedAddresses internal bridgehubAddresses;
    BridgesDeployedAddresses internal bridges;
    AddressIntrospector.BridgehubAddresses internal discoveredBridgehub;
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

    /// @notice E2e upgrade generation
    function run() public virtual {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    function getDiscoveredBridgehub() public view returns (AddressIntrospector.BridgehubAddresses memory) {
        return discoveredBridgehub;
    }

    function getNewProtocolVersion() public virtual returns (uint256) {
        return config.contracts.chainCreationParams.latestProtocolVersion;
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

    function isPatchUpgrade() public virtual returns (bool) {
        (uint32 _major, uint32 _minor, uint32 patch) = SemVer.unpackSemVer(SafeCast.toUint96(getNewProtocolVersion()));
        return patch != 0;
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

        config.eraChainId = toml.readUint("$.era_chain_id");
        nonDisoverable.bytecodesSupplier = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");
        nonDisoverable.rollupDAManager = toml.readAddress("$.contracts.rollup_da_manager");
        bridgehub = L1Bridgehub(toml.readAddress("$.contracts.bridgehub_proxy_address"));
        if (toml.keyExists("$.is_zk_sync_os")) {
            config.isZKsyncOS = toml.readBool("$.is_zk_sync_os");
        }
        setAddressesBasedOnBridgehub();

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;
        config.ownerAddress = discoveredBridgehub.governance;

        config.contracts.governanceSecurityCouncilAddress = Governance(payable(discoveredBridgehub.governance))
            .securityCouncil();
        config.contracts.governanceMinDelay = Governance(payable(discoveredBridgehub.governance)).minDelay();
        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();

        // Default values for initializing the chain. They are part of the chain creation params,
        // meanwhile they are not saved anywhere
        config.contracts.chainCreationParams.latestProtocolVersion = toml.readUint(
            "$.contracts.latest_protocol_version"
        );
        config.contracts.chainCreationParams.priorityTxMaxGasLimit = toml.readUint(
            "$.contracts.priority_tx_max_gas_limit"
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

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }

        newConfig.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");

        // L2 transactions params
        newConfig.priorityTxsL2GasLimit = toml.readUint("$.priority_txs_l2_gas_limit");
        newConfig.maxExpectedL1GasPrice = toml.readUint("$.max_expected_l1_gas_price");
    }

    function getBridgehubAdmin() public virtual returns (address admin) {
        admin = discoveredBridgehub.admin;
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        discoveredBridgehub = AddressIntrospector.getBridgehubAddresses(bridgehub);
        config.ownerAddress = discoveredBridgehub.governance;

        bridges.l1AssetRouterProxy = discoveredBridgehub.assetRouter;

        bridges.l1NullifierProxy = address(L1AssetRouter(bridges.l1AssetRouterProxy).L1_NULLIFIER());
        bridges.erc20BridgeProxy = address(L1AssetRouter(bridges.l1AssetRouterProxy).legacyBridge());

        newConfig.ecosystemAdminAddress = discoveredBridgehub.admin;
    }

    function getGovernanceUpgradeInitialDelay() external view virtual returns (uint256) {
        return newConfig.governanceUpgradeTimerInitialDelay;
    }

    function saveOutput(string memory outputPath) internal virtual {
        // Serialize bridgehub addresses
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", discoveredBridgehub.bridgehubProxy);
        vm.serializeAddress("bridgehub", "bridgehub_implementation_addr", bridgehubAddresses.bridgehubImplementation);
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            bridgehubAddresses.ctmDeploymentTrackerImplementation
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            bridgehubAddresses.ctmDeploymentTrackerProxy
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            bridgehubAddresses.chainAssetHandlerImplementation
        );
        vm.serializeAddress("bridgehub", "chain_asset_handler_proxy_addr", bridgehubAddresses.chainAssetHandlerProxy);
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", bridgehubAddresses.messageRootProxy);
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            bridgehubAddresses.messageRootImplementation
        );

        // Serialize bridges addresses
        vm.serializeAddress("bridges", "erc20_bridge_implementation_addr", bridges.erc20BridgeImplementation);
        vm.serializeAddress("bridges", "erc20_bridge_proxy_addr", bridges.erc20BridgeProxy);
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", bridges.l1NullifierProxy);
        vm.serializeAddress("bridges", "l1_nullifier_implementation_addr", bridges.l1NullifierImplementation);
        vm.serializeAddress("bridges", "l1_asset_router_implementation_addr", bridges.l1AssetRouterImplementation);
        vm.serializeAddress("bridges", "l1_asset_router_proxy_addr", bridges.l1AssetRouterProxy);
        // TODO: legacy name
        vm.serializeAddress("bridges", "shared_bridge_implementation_addr", bridges.l1AssetRouterImplementation);
        vm.serializeAddress("bridges", "bridged_standard_erc20_impl", bridges.bridgedStandardERC20Implementation);

        string memory bridgesSerialized = vm.serializeAddress(
            "bridges",
            "bridged_token_beacon",
            bridges.bridgedTokenBeacon
        );

        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridgesSerialized);
        vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            discoveredBridgehub.assetRouterAddresses.nativeTokenVault
        );
        vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_implementation_addr",
            upgradeAddresses.nativeTokenVaultImplementation
        );

        vm.serializeAddress("root", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        vm.serializeBytes32("root", "create2_factory_salt", create2FactoryParams.factorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeAddress("root", "owner_address", config.ownerAddress);
        vm.serializeAddress("root", "transparent_proxy_admin", addresses.transparentProxyAdmin);

        vm.serializeBytes("root", "governance_calls", new bytes(0)); // Will be populated later
        vm.serializeBytes("root", "ecosystem_admin_calls", new bytes(0)); // Will be populated later
        vm.serializeBytes("root", "test_upgrade_calls", new bytes(0)); // Will be populated later
        vm.serializeBytes("root", "v29", new bytes(0)); // Will be populated later

        vm.serializeUint(
            "root",
            "governance_upgrade_timer_initial_delay",
            newConfig.governanceUpgradeTimerInitialDelay
        );

        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    function saveOutputVersionSpecific() public virtual {}

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

    /// @notice The zeroth step of upgrade. By default it just stops gateway migrations
    function prepareStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](4);

        allCalls[0] = preparePauseGatewayMigrationsCall();
        allCalls[1] = prepareVersionSpecificStage0GovernanceCallsL1();
        allCalls[3] = prepareGovernanceUpgradeTimerStartCall();

        calls = mergeCallsArray(allCalls);
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](8);

        allCalls[0] = prepareGovernanceUpgradeTimerCheckCall();
        allCalls[1] = prepareCheckMigrationsPausedCalls();
        console.log("prepareStage1GovernanceCalls: prepareUpgradeProxiesCalls");
        allCalls[2] = prepareUpgradeProxiesCalls();
        allCalls[3] = provideSetNewVersionUpgradeCall();
        console.log("prepareStage1GovernanceCalls: prepareGatewaySpecificStage1GovernanceCalls");
        allCalls[4] = prepareVersionSpecificStage1GovernanceCallsL1();

        calls = mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](5);

        allCalls[0] = prepareCheckUpgradeIsPresent();
        allCalls[2] = prepareVersionSpecificStage2GovernanceCallsL1();
        allCalls[4] = prepareCheckMigrationsUnpausedCalls();

        calls = mergeCallsArray(allCalls);
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

    // TODO looks like we have to set it for bridgehub too
    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {
        //        require(discoveredCTM.ctmProxy != address(0), "stateTransitionManagerAddress is zero in newConfig");
        //
        //        // Just retrieved it from the contract
        //        uint256 previousProtocolVersion = getOldProtocolVersion();
        //        uint256 deadline = getOldProtocolDeadline();
        //        uint256 newProtocolVersion = getNewProtocolVersion();
        //        Diamond.DiamondCutData memory upgradeCut = abi.decode(
        //            newlyGeneratedData.upgradeCutData,
        //            (Diamond.DiamondCutData)
        //        );
        //        Call memory ctmCall = Call({
        //            target: discoveredCTM.ctmProxy,
        //            data: abi.encodeCall(
        //                IChainTypeManager.setNewVersionUpgrade,
        //                (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
        //            ),
        //            value: 0
        //        });
        //
        //        calls = new Call[](1);
        //        calls[0] = ctmCall;
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
    function prepareUpgradeProxiesCalls() public virtual returns (Call[] memory calls) {
        calls = new Call[](7);

        calls[0] = _buildCallProxyUpgrade(
            discoveredBridgehub.bridgehubProxy,
            bridgehubAddresses.bridgehubImplementation
        );

        // Note, that we do not need to run the initializer
        calls[1] = _buildCallProxyUpgrade(bridges.l1NullifierProxy, bridges.l1NullifierImplementation);

        calls[2] = _buildCallProxyUpgrade(bridges.l1AssetRouterProxy, bridges.l1AssetRouterImplementation);

        calls[3] = _buildCallProxyUpgrade(
            discoveredBridgehub.assetRouterAddresses.nativeTokenVault,
            upgradeAddresses.nativeTokenVaultImplementation
        );

        calls[4] = _buildCallProxyUpgrade(
            discoveredBridgehub.messageRoot,
            bridgehubAddresses.messageRootImplementation
        );

        calls[5] = _buildCallProxyUpgrade(
            discoveredBridgehub.l1CtmDeployer,
            bridgehubAddresses.ctmDeploymentTrackerImplementation
        );

        calls[6] = _buildCallProxyUpgrade(bridges.erc20BridgeProxy, bridges.erc20BridgeImplementation);
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

    function getAddresses() public view returns (DeployedAddresses memory) {
        return addresses;
    }

    function deployUpgradeStageValidator() internal {
        upgradeAddresses.upgradeStageValidator = deploySimpleContract("UpgradeStageValidator", false);
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

    // add this to be excluded from coverage report
    function test() internal override {}
}
