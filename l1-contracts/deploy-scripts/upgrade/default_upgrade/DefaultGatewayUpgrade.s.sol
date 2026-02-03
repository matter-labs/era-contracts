// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig, StateTransitionDeployedAddresses, ZkChainAddresses} from "../../utils/Types.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
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
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IValidatorTimelock} from "contracts/state-transition/IValidatorTimelock.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {CTMUpgradeBase} from "./CTMUpgradeBase.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";

/// @notice Script used for default CTM on gateway upgrade flow, should be run after L1 CTM upgrade
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultGatewayUpgrade is Script, CTMUpgradeBase {
    using stdToml for string;

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // solhint-disable-next-line gas-struct-packing
    struct AdditionalConfig {
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
        StateTransitionDeployedAddresses gatewayStateTransition;
        address gatewayTransparentProxyAdmin;
        bytes facetCutsData;
        uint256 chainId;
        bytes upgradeCutData;
    }

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        bool upgradeCutPrepared;
        string outputPath;
    }

    AdditionalConfig internal newConfig;
    Gateway internal gatewayConfig;
    ZkChainAddresses internal discoveredEraZkChain;
    L1Bridgehub internal bridgehub;
    CTMDeployedAddresses internal ctmDeployedAddresses;

    // TODO We need for composing upgrade transaction. but seems we don't need an upgrade transaction on gateway
    uint256[] internal factoryDepsHashes;
    mapping(bytes32 => bool) internal isHashInFactoryDeps;

    EcosystemUpgradeConfig internal upgradeConfig;

    function initialize(
        string memory permanentValuesInputPath,
        string memory newConfigPath,
        string memory _outputPath
    ) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);
        permanentValuesInputPath = string.concat(root, permanentValuesInputPath);
        initializeConfigFromFile(permanentValuesInputPath, newConfigPath);

        console.log("Initialized config from %s", newConfigPath);
        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    function initializeConfig(
        bytes32 _create2FactorySalt,
        address _create2FactoryAddr,
        bool _isZKsyncOS,
        ChainCreationParamsConfig memory _chainCreationParams,
        uint256 _eraChainId,
        uint256 _priorityTxsL2GasLimit,
        uint256 _maxExpectedL1GasPrice,
        Gateway memory _gatewayConfig,
        // Optional
        address _governance
    ) public {
        _initCreate2FactoryParams(_create2FactoryAddr, _create2FactorySalt);
        config.l1ChainId = block.chainid;
        config.eraChainId = _eraChainId;
        setAddressesBasedOnBridgehub();
        config.isZKsyncOS = _isZKsyncOS;
        config.contracts.chainCreationParams = _chainCreationParams;
        if (_governance != address(0)) {
            config.ownerAddress = _governance;
        } else {
            config.ownerAddress = ctmDeployedAddresses.admin.governance;
        }
        newConfig.ecosystemAdminAddress = ctmDeployedAddresses.admin.governance;
        newConfig.priorityTxsL2GasLimit = _priorityTxsL2GasLimit;
        newConfig.maxExpectedL1GasPrice = _maxExpectedL1GasPrice;
        gatewayConfig = _gatewayConfig;

        config.contracts.governanceSecurityCouncilAddress = Governance(payable(ctmDeployedAddresses.admin.governance))
            .securityCouncil();
        // config.contracts.governanceMinDelay = Governance(payable(ctmDeployedAddresses.admin.governance)).minDelay();
        config.contracts.validatorTimelockExecutionDelay = IValidatorTimelock(
            ctmDeployedAddresses.stateTransition.proxies.validatorTimelock
        ).executionDelay();
        (bool ok, bytes memory data) = ctmDeployedAddresses.stateTransition.verifiers.verifier.staticcall(
            abi.encodeWithSignature("IS_TESTNET_VERIFIER()")
        );
        config.testnetVerifier = ok;
        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();
    }

    function initializeConfigFromFile(
        string memory permanentValuesInputPath,
        string memory newConfigPath
    ) internal virtual {
        string memory permanentValuesToml = vm.readFile(permanentValuesInputPath);
        string memory toml = vm.readFile(newConfigPath);

        (address create2FactoryAddr, bytes32 create2FactorySalt) = getPermanentValues(permanentValuesInputPath);

        // Can we safely get it from the CTM? is it always exists even for zksync os ?
        uint256 eraChainId = permanentValuesToml.readUint("$.era_chain_id");

        address governance;
        if (toml.keyExists("$.governance")) {
            governance = toml.readAddress("$.governance");
        } else {
            governance = address(0);
        }

        // TODO can we discover it?. Try to get it from the chain
        bool isZKsyncOS;
        if (permanentValuesToml.keyExists("$.is_zk_sync_os")) {
            isZKsyncOS = permanentValuesToml.readBool("$.is_zk_sync_os");
        }
        ChainCreationParamsConfig memory chainCreationParams = getChainCreationParamsConfig(
            chainCreationParamsPath(isZKsyncOS)
        );

        Gateway memory gateway;
        // Gateway params
        gateway.chainId = permanentValuesToml.readUint("$.gateway.chain_id");
        gateway.gatewayStateTransition.proxies.chainTypeManager = permanentValuesToml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_proxy_addr"
        );

        gateway.gatewayTransparentProxyAdmin = permanentValuesToml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_proxy_admin"
        );

        gateway.gatewayStateTransition.rollupDAManager = permanentValuesToml.readAddress(
            "$.gateway.gateway_state_transition.rollup_da_manager"
        );

        gateway.gatewayStateTransition.rollupSLDAValidator = permanentValuesToml.readAddress(
            "$.gateway.gateway_state_transition.rollup_sl_da_validator"
        );

        // L2 transactions params
        uint priorityTxsL2GasLimit = permanentValuesToml.readUint("$.priority_txs_l2_gas_limit");
        uint maxExpectedL1GasPrice = permanentValuesToml.readUint("$.max_expected_l1_gas_price");

        initializeConfig(
            create2FactorySalt,
            create2FactoryAddr,
            isZKsyncOS,
            chainCreationParams,
            eraChainId,
            priorityTxsL2GasLimit,
            maxExpectedL1GasPrice,
            gateway,
            governance
        );
    }

    function isHashInFactoryDepsCheck(bytes32 bytecodeHash) internal view virtual override returns (bool) {
        return isHashInFactoryDeps[bytecodeHash];
    }

    /// @notice Full default upgrade preparation flow
    function prepareEcosystemUpgrade() public virtual {
        console.log("Ecosystem contracts are deployed!");
        deployNewEcosystemContractsGW();
        console.log("Ecosystem contracts for GW are deployed!");
        generateUpgradeData();
        console.log("Upgrade data generated!");
    }

    function deployGWContract(string memory contractName) internal returns (address contractAddress) {
        bytes memory creationCalldata = getCreationCalldata(contractName, true);
        contractAddress = Utils.deployThroughL1Deterministic(
            getCreationCode(contractName, true),
            creationCalldata,
            0,
            newConfig.priorityTxsL2GasLimit,
            new bytes[](0),
            gatewayConfig.chainId,
            coreAddresses.bridgehub.proxies.bridgehub,
            coreAddresses.bridges.proxies.l1AssetRouter
        );
        notifyAboutDeployment(contractAddress, contractName, creationCalldata, contractName, true);
    }

    /// @notice Generate data required for the upgrade
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");

        gatewayConfig.facetCutsData = abi.encode(getChainCreationDiamondCutData(gatewayConfig.gatewayStateTransition));
        console.log("Prepared diamond cut data");
        Diamond.DiamondCutData memory upgradeCutData = generateUpgradeCutData(
            gatewayConfig.gatewayStateTransition,
            config.contracts.chainCreationParams,
            config.l1ChainId,
            config.ownerAddress,
            factoryDepsHashes,
            discoveredEraZkChain.zkChainProxy,
            config.isZKsyncOS
        );
        gatewayConfig.upgradeCutData = abi.encode(upgradeCutData);
        upgradeConfig.upgradeCutPrepared = true;
        console.log("UpgradeCutGenerated");
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("UPGRADE_GATEWAY_INPUT"),
            vm.envString("UPGRADE_GATEWAY_OUTPUT")
        );
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function getNewProtocolVersion() public virtual returns (uint256) {
        return config.contracts.chainCreationParams.latestProtocolVersion;
    }

    function getOldProtocolVersion() public virtual returns (uint256) {
        return newConfig.oldProtocolVersion;
    }

    function getEcosystemAdmin() external virtual returns (address) {
        return newConfig.ecosystemAdminAddress;
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(address(bridgehub));
        config.ownerAddress = coreAddresses.shared.governance;
        address ctm = bridgehub.chainTypeManager(config.eraChainId);
        ctmDeployedAddresses = AddressIntrospector.getCTMAddresses(ChainTypeManagerBase(ctm));
        discoveredEraZkChain = AddressIntrospector.getZkChainAddresses(
            IZKChain(bridgehub.getZKChain(config.eraChainId))
        );

        ctmDeployedAddresses.daAddresses.l1RollupDAValidator = discoveredEraZkChain.l1DAValidator;
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        newConfig.oldProtocolVersion = ctmProtocolVersion;
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );

        newConfig.oldValidatorTimelock = ctmDeployedAddresses.stateTransition.proxies.validatorTimelock;
        newConfig.ecosystemAdminAddress = coreAddresses.shared.bridgehubAdmin;
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
        Call[][] memory allCalls = new Call[][](1);

        allCalls[0] = prepareGatewaySpecificStage0GovernanceCalls();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);

        allCalls[0] = prepareGatewaySpecificStage1GovernanceCalls();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);

        allCalls[0] = prepareGatewaySpecificStage2GovernanceCalls();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
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

    function prepareGatewaySpecificStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        if (gatewayConfig.chainId == 0) return calls; // Gateway is unknown

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        Call[][] memory allCalls = new Call[][](2);
        allCalls[0] = preparePauseMigrationCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareVersionSpecificStage0GovernanceCallsGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function deployUsedUpgradeContractGW() internal virtual returns (address) {
        return deployGWContract("DefaultUpgrade");
    }

    /// @notice Deploy everything that should be deployed for GW
    function deployNewEcosystemContractsGW() public virtual {
        require(upgradeConfig.initialized, "Not initialized");

        gatewayConfig.gatewayStateTransition.verifiers.verifierFflonk = deployGWContract("EraVerifierFflonk");
        gatewayConfig.gatewayStateTransition.verifiers.verifierPlonk = deployGWContract("EraVerifierPlonk");
        gatewayConfig.gatewayStateTransition.verifiers.verifier = deployGWContract("Verifier");

        gatewayConfig.gatewayStateTransition.facets.executorFacet = deployGWContract("ExecutorFacet");
        gatewayConfig.gatewayStateTransition.facets.adminFacet = deployGWContract("AdminFacet");
        gatewayConfig.gatewayStateTransition.facets.mailboxFacet = deployGWContract("MailboxFacet");
        gatewayConfig.gatewayStateTransition.facets.gettersFacet = deployGWContract("GettersFacet");
        gatewayConfig.gatewayStateTransition.facets.diamondInit = deployGWContract("DiamondInit");
        gatewayConfig.gatewayStateTransition.defaultUpgrade = deployUsedUpgradeContractGW();
        gatewayConfig.gatewayStateTransition.genesisUpgrade = deployGWContract("L1GenesisUpgrade");

        string memory gwCtmContractName = config.isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        gatewayConfig.gatewayStateTransition.implementations.chainTypeManager = deployGWContract(gwCtmContractName);

        deployUpgradeSpecificContractsGW();
    }

    function deployUpgradeSpecificContractsGW() internal virtual {
        // Empty by default.
    }

    function prepareGatewaySpecificStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        if (gatewayConfig.chainId == 0) return calls; // Gateway is unknown

        Call[][] memory allCalls = new Call[][](5);

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        allCalls[0] = provideSetNewVersionUpgradeCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareNewChainCreationParamsCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[2] = prepareCTMImplementationUpgrade(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[3] = prepareDAValidatorCallGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[4] = prepareVersionSpecificStage1GovernanceCallsGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareGatewaySpecificStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        if (gatewayConfig.chainId == 0) return calls; // Gateway is unknown

        Call[][] memory allCalls = new Call[][](2);

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        allCalls[0] = prepareUnpauseMigrationCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareVersionSpecificStage2GovernanceCallsGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function provideSetNewVersionUpgradeCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.proxies.chainTypeManager != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = abi.decode(
            gatewayConfig.upgradeCutData,
            (Diamond.DiamondCutData)
        );

        bytes memory l2Calldata = abi.encodeCall(
            IChainTypeManager.setNewVersionUpgrade,
            (
                upgradeCutData,
                previousProtocolVersion,
                deadline,
                newProtocolVersion,
                gatewayConfig.gatewayStateTransition.verifiers.verifier
            )
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.proxies.chainTypeManager
        );
    }

    function preparePauseMigrationCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(IChainAssetHandler.pauseMigration, ());

        calls = _prepareL1ToGatewayCall(l2Calldata, l2GasLimit, l1GasPrice, L2_CHAIN_ASSET_HANDLER_ADDR);
    }

    function prepareUnpauseMigrationCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(IChainAssetHandler.unpauseMigration, ());

        calls = _prepareL1ToGatewayCall(l2Calldata, l2GasLimit, l1GasPrice, L2_CHAIN_ASSET_HANDLER_ADDR);
    }

    function prepareNewChainCreationParamsCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.proxies.chainTypeManager != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        bytes memory l2Calldata = abi.encodeCall(
            IChainTypeManager.setChainCreationParams,
            (getChainCreationParams(gatewayConfig.gatewayStateTransition))
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.proxies.chainTypeManager
        );
    }

    function prepareCTMImplementationUpgrade(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.proxies.chainTypeManager != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        bytes memory l2Calldata = abi.encodeCall(
            ProxyAdmin.upgrade,
            (
                ITransparentUpgradeableProxy(payable(gatewayConfig.gatewayStateTransition.proxies.chainTypeManager)),
                gatewayConfig.gatewayStateTransition.implementations.chainTypeManager
            )
        );

        calls = _prepareL1ToGatewayCall(l2Calldata, l2GasLimit, l1GasPrice, gatewayConfig.gatewayTransparentProxyAdmin);
    }

    function _prepareL1ToGatewayCall(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        uint256 l1GasPrice,
        address dstAddress
    ) internal view returns (Call[] memory calls) {
        require(gatewayConfig.chainId != 0, "Chain id of gateway is zero in newConfig");

        require(coreAddresses.bridgehub.proxies.bridgehub != address(0), "bridgehubProxyAddress is zero in newConfig");
        require(
            coreAddresses.bridges.proxies.l1AssetRouter != address(0),
            "l1AssetRouterProxyAddress is zero in newConfig"
        );

        calls = Utils.prepareGovernanceL1L2DirectTransaction(
            l1GasPrice,
            l2Calldata,
            l2GasLimit,
            new bytes[](0),
            dstAddress,
            gatewayConfig.chainId,
            coreAddresses.bridgehub.proxies.bridgehub,
            coreAddresses.bridges.proxies.l1AssetRouter,
            msg.sender
        );
    }

    function prepareApproveGatewayBaseTokenCall(
        address spender,
        uint256 amount
    ) public virtual returns (Call[] memory calls) {
        address token = IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).baseToken(gatewayConfig.chainId);
        require(token != address(0), "Base token for Gateway is zero");
        calls = new Call[](1);
        calls[0] = Call({target: token, data: abi.encodeCall(IERC20.approve, (spender, amount)), value: 0});
    }

    function prepareDAValidatorCallGW(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(
            RollupDAManager.updateDAPair,
            (gatewayConfig.gatewayStateTransition.rollupSLDAValidator, getRollupL2DACommitmentScheme(), true)
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.rollupDAManager
        );
    }

    function getAddresses() public view virtual override returns (CTMDeployedAddresses memory) {
        return ctmDeployedAddresses;
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        require(isZKBytecode, "Only ZK bytecodes is not supported in Gateway upgrade");
        if (compareStrings(contractName, "DefaultUpgrade")) {
            return Utils.readZKFoundryBytecodeL1("DefaultUpgrade.sol", "DefaultUpgrade");
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return Utils.readZKFoundryBytecodeL1("BytecodesSupplier.sol", "BytecodesSupplier");
        } else if (compareStrings(contractName, "TransitionaryOwner")) {
            return Utils.readZKFoundryBytecodeL1("TransitionaryOwner.sol", "TransitionaryOwner");
        } else if (compareStrings(contractName, "L2LegacySharedBridge")) {
            return ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacy");
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return ContractsBytecodesLib.getCreationCode("ValidatorTimelock");
        }
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function saveOutputVersionSpecific() internal virtual {}

    function saveOutput(string memory outputPath) internal virtual override {
        // Serialize newly deployed gateway state transition addresses
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_implementation_addr",
            gatewayConfig.gatewayStateTransition.implementations.chainTypeManager
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_proxy",
            gatewayConfig.gatewayStateTransition.proxies.chainTypeManager
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_proxy_admin",
            gatewayConfig.gatewayTransparentProxyAdmin
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "rollup_da_manager",
            gatewayConfig.gatewayStateTransition.rollupDAManager
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "rollup_l2_da_validator",
            gatewayConfig.gatewayStateTransition.rollupSLDAValidator
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "admin_facet_addr",
            gatewayConfig.gatewayStateTransition.facets.adminFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "mailbox_facet_addr",
            gatewayConfig.gatewayStateTransition.facets.mailboxFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "executor_facet_addr",
            gatewayConfig.gatewayStateTransition.facets.executorFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "getters_facet_addr",
            gatewayConfig.gatewayStateTransition.facets.gettersFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "diamond_init_addr",
            gatewayConfig.gatewayStateTransition.facets.diamondInit
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "default_upgrade_addr",
            gatewayConfig.gatewayStateTransition.defaultUpgrade
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "genesis_upgrade_addr",
            gatewayConfig.gatewayStateTransition.genesisUpgrade
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "verifier_addr",
            gatewayConfig.gatewayStateTransition.verifiers.verifier
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "verifier_fflonk_addr",
            gatewayConfig.gatewayStateTransition.verifiers.verifierFflonk
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "validator_timelock_implementation_addr",
            gatewayConfig.gatewayStateTransition.implementations.validatorTimelock
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "validator_timelock_addr",
            gatewayConfig.gatewayStateTransition.proxies.validatorTimelock
        );
        string memory gateway_state_transition = vm.serializeAddress(
            "gateway_state_transition",
            "verifier_plonk_addr",
            gatewayConfig.gatewayStateTransition.verifiers.verifierPlonk
        );

        // Serialize generated gateway data
        vm.serializeBytes("gateway", "diamond_cut_data", gatewayConfig.facetCutsData);
        vm.serializeBytes("gateway", "upgrade_cut_data", gatewayConfig.upgradeCutData);
        string memory gateway = vm.serializeString("gateway", "gateway_state_transition", gateway_state_transition);

        // Serialize root structure
        string memory toml = vm.serializeString("root", "gateway", gateway);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    // add this to be excluded from coverage report
    function test() internal override {}
}
