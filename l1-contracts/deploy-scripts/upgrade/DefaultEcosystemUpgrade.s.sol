// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {PrepareL1L2TransactionParams, StateTransitionDeployedAddresses, Utils} from "../Utils.sol";
import {L2_BRIDGEHUB_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehub, L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehub.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {GatewayUpgrade, GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
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
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {ContractsBytecodesLib} from "../ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "./SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "./BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {Create2AndTransfer} from "../Create2AndTransfer.sol";

import {ContractsConfig, DeployedAddresses, TokensConfig} from "../DeployUtils.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {DeployL1Script} from "../DeployL1.s.sol";
import {Gateway, EcosystemUpgradeConfig} from "./UpgradeUtils.sol";


/// @notice Script used for default upgrade flow
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultEcosystemUpgrade is Script, DeployL1Script {
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
        ExpectedL2Addresses expectedL2Addresses;
        address gatewayUpgrade;
        address transitionaryOwner;
        address upgradeTimer;
        address bytecodesSupplier;
        address l2WrappedBaseTokenStore;
        address upgradeStageValidator;
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
        uint256 oldProtocolVersion;
        address oldValidatorTimelock;
        uint256 priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice;
    }



    // solhint-disable-next-line gas-struct-packing
    struct NewlyGeneratedData {
        bytes fixedForceDeploymentsData;
        bytes diamondCutData;
        bytes upgradeCutData;
    }



    AdditionalConfig internal newConfig;
    Gateway internal gatewayConfig;
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
        deployNewEcosystemContractsL1();
        console.log("Ecosystem contracts are deployed!");
        deployNewEcosystemContractsGW();
        console.log("Ecosystem contracts for GW are deployed!");
        publishBytecodes();
        console.log("Bytecodes published!");
        generateUpgradeData();
        console.log("Upgrade data generated!");
    }

    function deployUsedUpgradeContract() internal virtual returns (address) {
        return deploySimpleContract("DefaultUpgrade", false);
    }

    /// @notice Deploy everything that should be deployed
    function deployNewEcosystemContractsL1() public virtual {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        deployVerifiers();
        deployUpgradeStageValidator();

        // Note, that this is the upgrade that will be used, despite the naming of the variable here.
        // To use the custom upgrade simply override the `deployUsedUpgradeContract` function.

        // TODO(refactor): rename to "upgrade contract", it is not a default upgrade.
        (addresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        (addresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        addresses.bridgehub.bridgehubImplementation = deploySimpleContract("Bridgehub", false);

        addresses.bridges.l1NullifierImplementation = deploySimpleContract("L1Nullifier", false);
        addresses.bridges.l1AssetRouterImplementation = deploySimpleContract("L1AssetRouter", false);
        addresses.vaults.l1NativeTokenVaultImplementation = deploySimpleContract("L1NativeTokenVault", false);
        addresses.bridges.erc20BridgeImplementation = deploySimpleContract("L1ERC20Bridge", false);
        addresses.bridges.bridgedStandardERC20Implementation = deploySimpleContract("BridgedStandardERC20", false);

        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        addresses.bridgehub.messageRootImplementation = deploySimpleContract("MessageRoot", false);
        addresses.bridgehub.ctmDeploymentTrackerImplementation = deploySimpleContract("CTMDeploymentTracker", false);

        deployStateTransitionDiamondFacets();

        addresses.stateTransition.chainTypeManagerImplementation = deploySimpleContract("ChainTypeManager", false);

        addresses.stateTransition.serverNotifierImplementation = deploySimpleContract("ServerNotifier", false);

        /// for forge verification.
        deploySimpleContract("DiamondProxy", false);

        deployUpgradeSpecificContractsL1();

        upgradeConfig.ecosystemContractsDeployed = true;
    }

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

    function deployGWContract(string memory contractName) internal returns (address contractAddress) {
        bytes memory creationCalldata = getCreationCalldata(contractName, true);
        contractAddress = Utils.deployThroughL1Deterministic(
            getCreationCode(contractName, true),
            creationCalldata,
            0,
            newConfig.priorityTxsL2GasLimit,
            new bytes[](0),
            gatewayConfig.chainId,
            addresses.bridgehub.bridgehubProxy,
            addresses.bridges.l1AssetRouterProxy
        );
        notifyAboutDeployment(contractAddress, contractName, creationCalldata, contractName, true);
    }

    function deployGWTuppWithContract(string memory contractName) internal returns (address proxyAddress) {
        bytes memory creationCalldata = getCreationCalldata(contractName, true);
        address implementation = Utils.deployThroughL1Deterministic(
            getCreationCode(contractName, true),
            creationCalldata,
            0,
            newConfig.priorityTxsL2GasLimit,
            new bytes[](0),
            gatewayConfig.chainId,
            addresses.bridgehub.bridgehubProxy,
            addresses.bridges.l1AssetRouterProxy
        );
        notifyAboutDeployment(implementation, contractName, creationCalldata, contractName, true);

        bytes memory proxyCreationCalldata = abi.encode(
            implementation,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxyAdmin,
            getInitializeCalldata(contractName, true)
        );
        proxyAddress = Utils.deployThroughL1Deterministic(
            ContractsBytecodesLib.getCreationCode("TransparentUpgradeableProxy"),
            proxyCreationCalldata,
            0,
            newConfig.priorityTxsL2GasLimit,
            new bytes[](0),
            gatewayConfig.chainId,
            addresses.bridgehub.bridgehubProxy,
            addresses.bridges.l1AssetRouterProxy
        );
        notifyAboutDeployment(
            proxyAddress,
            contractName,
            proxyCreationCalldata,
            string.concat(contractName, " Proxy"),
            true
        );
    }

    /// @notice Generate data required for the upgrade
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Important, this must come after the initializeExpectedL2Addresses
        generateFixedForceDeploymentsData();
        console.log("Generated fixed force deployments data");
        getDiamondCutData(addresses.stateTransition);
        newlyGeneratedData.diamondCutData = config.contracts.diamondCutData;
        gatewayConfig.facetCutsData = abi.encode(getDiamondCutData(gatewayConfig.gatewayStateTransition));
        console.log("Prepared diamond cut data");
        generateUpgradeCutData(addresses.stateTransition);
        generateUpgradeCutData(gatewayConfig.gatewayStateTransition);
        upgradeConfig.upgradeCutPrepared = true;
        console.log("UpgradeCutGenerated");
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
        prepareDefaultEcosystemAdminCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        address diamondProxy = ChainTypeManager(addresses.stateTransition.chainTypeManagerProxy).getHyperchain(
            config.eraChainId
        );
        IZKChain.Facet[] memory facets = IZKChain(diamondProxy).facets();

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

        (address target, bytes memory data) = _getL2UpgradeTargetAndData(forceDeployments);

        transaction = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(target)),
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

    function _getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal virtual returns (address, bytes memory) {
        return (
            address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR),
            abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (_forceDeployments))
        );
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

        Diamond.FacetCut[] memory facetCuts = getFacetCutsOuter(stateTransition);

        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade(stateTransition);

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });

        if (!stateTransition.isOnGateway) {
            newlyGeneratedData.upgradeCutData = abi.encode(upgradeCutData);
        } else {
            gatewayConfig.upgradeCutData = abi.encode(upgradeCutData);
        }
    }

    function getFacetCutsOuter(
        StateTransitionDeployedAddresses memory stateTransition
    ) public virtual returns (Diamond.FacetCut[] memory facetCuts) {
        Diamond.FacetCut[] memory facetCutsForDeletion = getFacetCutsForDeletion();

        Diamond.FacetCut[] memory facetCuts;
        facetCuts = formatFacetCuts(getFacetCuts(stateTransition));
        facetCuts = mergeFacets(facetCutsForDeletion, facetCuts);
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
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            evmEmulatorHash: config.contracts.evmEmulatorHash,
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
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        addresses.stateTransition.bytecodesSupplier = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");

        addresses.bridgehub.bridgehubProxy = toml.readAddress("$.contracts.bridgehub_proxy_address");

        setAddressesBasedOnBridgehub();

        addresses.transparentProxyAdmin = address(
            uint160(uint256(vm.load(addresses.bridgehub.bridgehubProxy, ADMIN_SLOT)))
        );
        require(
            Ownable2StepUpgradeable(addresses.bridgehub.bridgehubProxy).owner() == config.ownerAddress,
            "Incorrect owner"
        );

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
        newConfig.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");

        newConfig.oldProtocolVersion = toml.readUint("$.old_protocol_version");

        newConfig.priorityTxsL2GasLimit = toml.readUint("$.priority_txs_l2_gas_limit");
        newConfig.maxExpectedL1GasPrice = toml.readUint("$.max_expected_l1_gas_price");

        addresses.daAddresses.rollupDAManager = toml.readAddress("$.contracts.rollup_da_manager");

        gatewayConfig.gatewayStateTransition.chainTypeManagerProxy = toml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_proxy_addr"
        );

        gatewayConfig.gatewayStateTransition.chainTypeManagerProxyAdmin = toml.readAddress(
            "$.gateway.gateway_state_transition.chain_type_manager_proxy_admin"
        );

        gatewayConfig.gatewayStateTransition.rollupDAManager = toml.readAddress(
            "$.gateway.gateway_state_transition.rollup_da_manager"
        );

        gatewayConfig.gatewayStateTransition.rollupSLDAValidator = toml.readAddress(
            "$.gateway.gateway_state_transition.rollup_sl_da_validator"
        );

        gatewayConfig.gatewayStateTransition.isOnGateway = true;

        gatewayConfig.chainId = toml.readUint("$.gateway.chain_id");
        config.gatewayChainId = gatewayConfig.chainId;
    }

    function getBridgehubAdmin() public virtual returns (address admin) {
        admin = Bridgehub(addresses.bridgehub.bridgehubProxy).admin();
    }

    /// @notice This function is meant to only be used in tests
    function prepareCreateNewChainCall(uint256 chainId) public view virtual returns (Call[] memory result) {
        require(addresses.bridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");

        bytes32 newChainAssetId = Bridgehub(addresses.bridgehub.bridgehubProxy).baseTokenAssetId(gatewayConfig.chainId);
        result = new Call[](1);
        result[0] = Call({
            target: addresses.bridgehub.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(
                IBridgehub.createNewChain,
                (
                    chainId,
                    addresses.stateTransition.chainTypeManagerProxy,
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
        addresses.stateTransition.serverNotifierProxy = ChainTypeManager(
            addresses.stateTransition.chainTypeManagerProxy
        ).serverNotifierAddress();

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
        string[2] memory expectedCreate2Deployed = ["RollupL2DAValidator", "NoDAL2DAValidator"];

        for (uint256 i; i < expectedCreate2Deployed.length; i++) {
            if (compareStrings(contractName, expectedCreate2Deployed[i])) {
                return Utils.getL2AddressViaCreate2Factory(bytes32(0), getL2BytecodeHash(contractName), hex"");
            }
        }

        revert(string.concat("No expected L2 address for: ", contractName));
    }

    function getGovernanceUpgradeInitialDelay() external view virtual returns (uint256) {
        return newConfig.governanceUpgradeTimerInitialDelay;
    }

    function getFullListOfFactoryDependencies() internal virtual returns (bytes[] memory factoryDeps) {
        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies();

        string[] memory additionalForceDeployments = getAdditionalDependenciesNames();

        bytes[] memory additionalDependencies = new bytes[](6 + additionalForceDeployments.length); // Deps after Gateway upgrade
        additionalDependencies[0] = ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacy");
        additionalDependencies[1] = ContractsBytecodesLib.getCreationCode("BridgedStandardERC20");
        additionalDependencies[2] = ContractsBytecodesLib.getCreationCode("RollupL2DAValidator");
        additionalDependencies[3] = ContractsBytecodesLib.getCreationCode("ValidiumL2DAValidator");
        // TODO(refactor): do we need this?
        additionalDependencies[4] = ContractsBytecodesLib.getCreationCode("DiamondProxy");
        additionalDependencies[5] = ContractsBytecodesLib.getCreationCode("L2V29Upgrade");

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
            l1AssetRouter: addresses.bridges.l1AssetRouterProxy,
            l2TokenProxyBytecodeHash: getL2BytecodeHash("BeaconProxy"),
            aliasedL1Governance: AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress),
            maxNumberOfZKChains: config.contracts.maxNumberOfChains,
            bridgehubBytecodeHash: getL2BytecodeHash("Bridgehub"),
            l2AssetRouterBytecodeHash: getL2BytecodeHash("L2AssetRouter"),
            l2NtvBytecodeHash: getL2BytecodeHash("L2NativeTokenVault"),
            messageRootBytecodeHash: getL2BytecodeHash("MessageRoot"),
            chainAssetHandlerBytecodeHash: getL2BytecodeHash("ChainAssetHandler"),
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            dangerousTestOnlyForcedBeacon: address(0)
        });
    }

    function saveOutput(string memory outputPath) internal virtual override {
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", addresses.bridgehub.bridgehubProxy);
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
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            addresses.bridgehub.chainAssetHandlerImplementation
        );
        vm.serializeAddress("bridgehub", "chain_asset_handler_proxy_addr", addresses.bridgehub.chainAssetHandlerProxy);
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

        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_implementation_addr",
            gatewayConfig.gatewayStateTransition.chainTypeManagerImplementation
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_proxy",
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_proxy_admin",
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxyAdmin
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
            gatewayConfig.gatewayStateTransition.adminFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "mailbox_facet_addr",
            gatewayConfig.gatewayStateTransition.mailboxFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "executor_facet_addr",
            gatewayConfig.gatewayStateTransition.executorFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "getters_facet_addr",
            gatewayConfig.gatewayStateTransition.gettersFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "diamond_init_addr",
            gatewayConfig.gatewayStateTransition.diamondInit
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
        vm.serializeAddress("gateway_state_transition", "verifier_addr", gatewayConfig.gatewayStateTransition.verifier);
        vm.serializeAddress(
            "gateway_state_transition",
            "verifier_fflonk_addr",
            gatewayConfig.gatewayStateTransition.verifierFflonk
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "validator_timelock_addr",
            gatewayConfig.gatewayStateTransition.validatorTimelock
        );

        string memory gateway_state_transition = vm.serializeAddress(
            "gateway_state_transition",
            "verifier_plonk_addr",
            gatewayConfig.gatewayStateTransition.verifierPlonk
        );

        vm.serializeBytes("gateway", "diamond_cut_data", gatewayConfig.facetCutsData);
        vm.serializeBytes("gateway", "upgrade_cut_data", gatewayConfig.upgradeCutData);
        string memory gateway = vm.serializeString("gateway", "gateway_state_transition", gateway_state_transition);

        vm.serializeUint("root", "gateway_chain_id", gatewayConfig.chainId);
        vm.serializeUint("root", "priority_txs_l2_gas_limit", newConfig.priorityTxsL2GasLimit);
        vm.serializeUint("root", "max_expected_l1_gas_price", newConfig.maxExpectedL1GasPrice);

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
        vm.serializeAddress("deployed_addresses", "l1_gateway_upgrade", upgradeAddresses.gatewayUpgrade);
        vm.serializeAddress("deployed_addresses", "l1_transitionary_owner", upgradeAddresses.transitionaryOwner);
        vm.serializeAddress("deployed_addresses", "upgrade_stage_validator", upgradeAddresses.upgradeStageValidator);
        vm.serializeAddress("deployed_addresses", "l1_rollup_da_manager", addresses.daAddresses.rollupDAManager);
        vm.serializeAddress(
            "deployed_addresses",
            "l2_wrapped_base_token_store_addr",
            upgradeAddresses.l2WrappedBaseTokenStore
        );

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            upgradeAddresses.upgradeTimer
        );

        vm.serializeAddress("root", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        vm.serializeBytes32("root", "create2_factory_salt", create2FactoryParams.factorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);
        vm.serializeAddress("root", "owner_address", config.ownerAddress);
        vm.serializeAddress("root", "protocol_upgrade_handler_proxy_address", config.ownerAddress);

        vm.serializeString("root", "gateway", gateway);

        vm.serializeBytes("root", "governance_calls", new bytes(0)); // Will be populated later
        vm.serializeBytes("root", "ecosystem_admin_calls", new bytes(0)); // Will be populated later

        vm.serializeUint(
            "root",
            "governance_upgrade_timer_initial_delay",
            newConfig.governanceUpgradeTimerInitialDelay
        );

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
        require(bytes32(factoryDeps[0]) == config.contracts.bootloaderHash, string.concat("bootloader hash factory dep mismatch ", vm.toString(bytes32(factoryDeps[0])), " != ", vm.toString(config.contracts.bootloaderHash)));
        require(bytes32(factoryDeps[1]) == config.contracts.defaultAAHash, string.concat("default aa hash factory dep mismatch ", vm.toString(bytes32(factoryDeps[1])), " != ", vm.toString(config.contracts.defaultAAHash)));
        require(bytes32(factoryDeps[2]) == config.contracts.evmEmulatorHash, string.concat("EVM emulator hash factory dep mismatch ", vm.toString(bytes32(factoryDeps[2])), " != ", vm.toString(config.contracts.evmEmulatorHash)));

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

    function prepareDefaultEcosystemAdminCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);
        allCalls[0] = prepareUpgradeServerNotifierCall();
        calls = mergeCallsArray(allCalls);

        string memory ecosystemAdminCallsSerialized = vm.serializeBytes(
            "ecosystem_admin_calls",
            "server_notifier_upgrade",
            abi.encode(calls)
        );

        vm.writeToml(ecosystemAdminCallsSerialized, upgradeConfig.outputPath, ".ecosystem_admin_calls");
    }

    function prepareUpgradeServerNotifierCall() public virtual returns (Call[] memory calls) {
        address serverNotifierProxyAdmin = address(
            uint160(uint256(vm.load(addresses.stateTransition.serverNotifierProxy, ADMIN_SLOT)))
        );

        Call memory call = Call({
            target: serverNotifierProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(addresses.stateTransition.serverNotifierProxy)),
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
        Call[][] memory allCalls = new Call[][](4);

        allCalls[0] = preparePauseGatewayMigrationsCall();
        allCalls[1] = prepareVersionSpecificStage0GovernanceCallsL1();
        allCalls[2] = prepareGatewaySpecificStage0GovernanceCalls();
        allCalls[3] = prepareGovernanceUpgradeTimerStartCall();

        calls = mergeCallsArray(allCalls);
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](8);

        allCalls[0] = prepareGovernanceUpgradeTimerCheckCall();
        allCalls[1] = prepareCheckMigrationsPausedCalls();
        allCalls[2] = prepareUpgradeProxiesCalls();
        allCalls[3] = prepareNewChainCreationParamsCall();
        allCalls[4] = provideSetNewVersionUpgradeCall();
        allCalls[5] = prepareDAValidatorCall();
        allCalls[6] = prepareVersionSpecificStage1GovernanceCallsL1();
        allCalls[7] = prepareGatewaySpecificStage1GovernanceCalls();

        calls = mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](5);

        allCalls[0] = prepareCheckUpgradeIsPresent();
        allCalls[1] = prepareUnpauseGatewayMigrationsCall();
        allCalls[2] = prepareVersionSpecificStage2GovernanceCallsL1();
        allCalls[3] = prepareGatewaySpecificStage2GovernanceCalls();
        allCalls[4] = prepareCheckMigrationsUnpausedCalls();

        calls = mergeCallsArray(allCalls);
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

    function prepareGatewaySpecificStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        if (gatewayConfig.chainId == 0) return calls; // Gateway is unknown

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        Call[][] memory allCalls = new Call[][](2);
        allCalls[0] = preparePauseMigrationCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareVersionSpecificStage0GovernanceCallsGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = mergeCallsArray(allCalls);
    }

    function deployUsedUpgradeContractGW() internal virtual returns (address) {
        return deployGWContract("DefaultUpgrade");
    }

    /// @notice Deploy everything that should be deployed for GW
    function deployNewEcosystemContractsGW() public virtual {
        require(upgradeConfig.initialized, "Not initialized");

        gatewayConfig.gatewayStateTransition.verifierFflonk = deployGWContract("VerifierFflonk");
        gatewayConfig.gatewayStateTransition.verifierPlonk = deployGWContract("VerifierPlonk");
        gatewayConfig.gatewayStateTransition.verifier = deployGWContract("Verifier");

        gatewayConfig.gatewayStateTransition.executorFacet = deployGWContract("ExecutorFacet");
        gatewayConfig.gatewayStateTransition.adminFacet = deployGWContract("AdminFacet");
        gatewayConfig.gatewayStateTransition.mailboxFacet = deployGWContract("MailboxFacet");
        gatewayConfig.gatewayStateTransition.gettersFacet = deployGWContract("GettersFacet");
        gatewayConfig.gatewayStateTransition.diamondInit = deployGWContract("DiamondInit");
        gatewayConfig.gatewayStateTransition.defaultUpgrade = deployUsedUpgradeContractGW();
        gatewayConfig.gatewayStateTransition.genesisUpgrade = deployGWContract("L1GenesisUpgrade");

        gatewayConfig.gatewayStateTransition.chainTypeManagerImplementation = deployGWContract("ChainTypeManager");

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

        calls = mergeCallsArray(allCalls);
    }

    function prepareGatewaySpecificStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        if (gatewayConfig.chainId == 0) return calls; // Gateway is unknown

        Call[][] memory allCalls = new Call[][](2);

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        allCalls[0] = prepareUnpauseMigrationCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareVersionSpecificStage2GovernanceCallsGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = mergeCallsArray(allCalls);
    }

    function provideSetNewVersionUpgradeCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        uint256 previousProtocolVersion = getOldProtocolVersion();
        uint256 deadline = getOldProtocolDeadline();
        uint256 newProtocolVersion = getNewProtocolVersion();
        Diamond.DiamondCutData memory upgradeCut = generateUpgradeCutData(gatewayConfig.gatewayStateTransition);

        bytes memory l2Calldata = abi.encodeCall(
            ChainTypeManager.setNewVersionUpgrade,
            (upgradeCut, previousProtocolVersion, deadline, newProtocolVersion)
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
    }

    function preparePauseMigrationCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(IBridgehub.pauseMigration, ());

        calls = _prepareL1ToGatewayCall(l2Calldata, l2GasLimit, l1GasPrice, L2_BRIDGEHUB_ADDR);
    }

    function prepareUnpauseMigrationCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(IBridgehub.unpauseMigration, ());

        calls = _prepareL1ToGatewayCall(l2Calldata, l2GasLimit, l1GasPrice, L2_BRIDGEHUB_ADDR);
    }

    function prepareNewChainCreationParamsCallForGateway(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        bytes memory l2Calldata = abi.encodeCall(
            ChainTypeManager.setChainCreationParams,
            (getChainCreationParams(gatewayConfig.gatewayStateTransition))
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
    }

    function prepareCTMImplementationUpgrade(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        require(
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy != address(0),
            "chainTypeManager on gateway is zero in newConfig"
        );

        bytes memory l2Calldata = abi.encodeCall(
            ProxyAdmin.upgrade,
            (
                ITransparentUpgradeableProxy(payable(gatewayConfig.gatewayStateTransition.chainTypeManagerProxy)),
                gatewayConfig.gatewayStateTransition.chainTypeManagerImplementation
            )
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxyAdmin
        );
    }

    function _prepareL1ToGatewayCall(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        uint256 l1GasPrice,
        address dstAddress
    ) internal view returns (Call[] memory calls) {
        require(gatewayConfig.chainId != 0, "Chain id of gateway is zero in newConfig");

        require(addresses.bridgehub.bridgehubProxy != address(0), "bridgehubProxyAddress is zero in newConfig");
        require(addresses.bridges.l1AssetRouterProxy != address(0), "l1AssetRouterProxyAddress is zero in newConfig");

        calls = Utils.prepareGovernanceL1L2DirectTransaction(
            l1GasPrice,
            l2Calldata,
            l2GasLimit,
            new bytes[](0),
            dstAddress,
            gatewayConfig.chainId,
            addresses.bridgehub.bridgehubProxy,
            addresses.bridges.l1AssetRouterProxy,
            msg.sender
        );
    }

    function prepareApproveGatewayBaseTokenCall(
        address spender,
        uint256 amount
    ) public virtual returns (Call[] memory calls) {
        address token = IBridgehub(addresses.bridgehub.bridgehubProxy).baseToken(gatewayConfig.chainId);
        require(token != address(0), "Base token for Gateway is zero");
        calls = new Call[](1);
        calls[0] = Call({target: token, data: abi.encodeCall(IERC20.approve, (spender, amount)), value: 0});
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
        calls = new Call[](8);

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

        calls[5] = _buildCallProxyUpgrade(
            addresses.bridgehub.messageRootProxy,
            addresses.bridgehub.messageRootImplementation
        );

        calls[6] = _buildCallProxyUpgrade(
            addresses.bridgehub.ctmDeploymentTrackerProxy,
            addresses.bridgehub.ctmDeploymentTrackerImplementation
        );

        calls[7] = _buildCallProxyUpgrade(
            addresses.bridges.erc20BridgeProxy,
            addresses.bridges.erc20BridgeImplementation
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
            target: addresses.daAddresses.rollupDAManager,
            data: abi.encodeCall(
                RollupDAManager.updateDAPair,
                (addresses.daAddresses.l1RollupDAValidator, getExpectedL2Address("RollupL2DAValidator"), true)
            ),
            value: 0
        });
    }

    function prepareDAValidatorCallGW(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(
            RollupDAManager.updateDAPair,
            (
                gatewayConfig.gatewayStateTransition.rollupSLDAValidator,
                getExpectedL2Address("RollupL2DAValidator"),
                true
            )
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.rollupDAManager
        );
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
            }
        } else {
            if (compareStrings(contractName, "GatewayUpgrade")) {
                return Utils.readZKFoundryBytecodeL1("GatewayUpgrade.sol", "GatewayUpgrade");
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return Utils.readZKFoundryBytecodeL1("DefaultUpgrade.sol", "DefaultUpgrade");
            } else if (compareStrings(contractName, "BytecodesSupplier")) {
                return Utils.readZKFoundryBytecodeL1("BytecodesSupplier.sol", "BytecodesSupplier");
            } else if (compareStrings(contractName, "TransitionaryOwner")) {
                return Utils.readZKFoundryBytecodeL1("TransitionaryOwner.sol", "TransitionaryOwner");
            } else if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
                return Utils.readZKFoundryBytecodeL1("GovernanceUpgradeTimer.sol", "GovernanceUpgradeTimer");
            } else if (compareStrings(contractName, "L2LegacySharedBridge")) {
                return ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacy");
            } else if (compareStrings(contractName, "L2StandardERC20")) {
                return ContractsBytecodesLib.getCreationCode("BridgedStandardERC20");
            } else if (compareStrings(contractName, "RollupL2DAValidator")) {
                return ContractsBytecodesLib.getCreationCode("RollupL2DAValidator");
            } else if (compareStrings(contractName, "NoDAL2DAValidator")) {
                return ContractsBytecodesLib.getCreationCode("ValidiumL2DAValidator");
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return ContractsBytecodesLib.getCreationCode("ValidatorTimelock");
            }
        }
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
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
            return abi.encode(initialDelay, MAX_ADDITIONAL_DELAY, config.ownerAddress, newConfig.ecosystemAdminAddress);
        } else if (compareStrings(contractName, "L2LegacySharedBridge")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L2StandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupL2DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "NoDAL2DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ChainTypeManager")) {
            if (!isZKBytecode) {
                return abi.encode(addresses.bridgehub.bridgehubProxy);
            } else {
                return abi.encode(L2_BRIDGEHUB_ADDR);
            }
        } else if (compareStrings(contractName, "VerifierFflonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "VerifierPlonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "Verifier")) {
            if (!isZKBytecode) {
                return abi.encode(addresses.stateTransition.verifierFflonk, addresses.stateTransition.verifierPlonk);
            } else {
                return
                    abi.encode(
                        gatewayConfig.gatewayStateTransition.verifierFflonk,
                        gatewayConfig.gatewayStateTransition.verifierPlonk
                    );
            }
        } else if (compareStrings(contractName, "AdminFacet")) {
            if (!isZKBytecode) {
                return abi.encode(config.l1ChainId, addresses.daAddresses.rollupDAManager);
            } else {
                return abi.encode(config.l1ChainId, gatewayConfig.gatewayStateTransition.rollupDAManager);
            }
        } else if (compareStrings(contractName, "UpgradeStageValidator")) {
            return abi.encode(addresses.stateTransition.chainTypeManagerProxy, config.contracts.latestProtocolVersion);
        } else if (compareStrings(contractName, "DiamondProxy")) {
            Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);
            Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
                facetCuts: facetCuts,
                initAddress: address(0),
                initCalldata: ""
            });
            return abi.encode(block.chainid, diamondCut);
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            if (!isZKBytecode) {
                return abi.encode(addresses.bridgehub.bridgehubProxy);
            } else {
                return abi.encode(L2_BRIDGEHUB_ADDR);
            }
        } else {
            return super.getCreationCalldata(contractName, isZKBytecode);
        }
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
