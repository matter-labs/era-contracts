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
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
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

import {L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";

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
    address l2BridgeProxyOwnerAddress;
    address l2BridgedStandardERC20ProxyOwnerAddress;
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
        address permanentRollupRestriction;
        address validatorTimelock;
        address gatewayUpgrade;
        address create2Factory;
        address transitionaryOwner;
    }

    struct ExpectedL2Addresses {
        address expectedRollupL2DAValidator;
        address expectedValidiumL2DAValidator;
        address expectedL2GatewayUpgrade;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
        // In reality, the following addresses need to be
        // deployed only on a settlement layer, i.e. the Gateway.
        address expectedL2ProxyAdminDeployer;
        address expectedL2ProxyAdmin;
        address expectedL2AdminFactory;
        address expectedL2PermanentRestrictionImpl;
        address expectedL2PermanentRestrictionProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct L1NativeTokenVaultAddresses {
        address l1NativeTokenVaultImplementation;
        address l1NativeTokenVaultProxy;
    }

    struct DataAvailabilityDeployedAddresses {
        address l1RollupDAValidator;
        address l1ValidiumDAValidator;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address ctmDeploymentTrackerImplementation;
        address ctmDeploymentTrackerProxy;
        address messageRootImplementation;
        address messageRootProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address sharedBridgeProxy;
        address sharedBridgeImplementation;
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
        bool testnetVerifier;
        ContractsConfig contracts;
        TokensConfig tokens;
    }

    // solhint-disable-next-line gas-struct-packing
    struct GeneratedData {
        bytes forceDeploymentsData;
        bytes diamondCutData;
    }

    // solhint-disable-next-line gas-struct-packing
    struct ContractsConfig {
        bytes32 create2FactorySalt;
        address create2FactoryAddr;
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
        uint256 maxNumberOfChains;
        bytes32 bootloaderHash;
        bytes32 defaultAAHash;
        address oldValidatorTimelock;
        address legacyErc20BridgeAddress;
        address bridgehubProxyAddress;
        address oldSharedBridgeProxyAddress;
        address stateTransitionManagerAddress;
        address transparentProxyAdmin;
        address eraDiamondProxy;
        address blobVersionedHashRetriever;
        address l2BridgeProxyOwnerAddress;
        address l2BridgedStandardERC20ProxyOwnerAddress;
    }

    struct TokensConfig {
        address tokenWethAddress;
    }

    Config internal config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    function prepareEcosystemContracts(string memory configPath, string memory outputPath) public {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(configPath);

        instantiateCreate2Factory();

        deployVerifier();
        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployGatewayUpgrade();

        deployDAValidators();
        deployValidatorTimelock();

        // TODO: restore
        // deployChainAdmin();
        deployBridgehubImplementation();
        deployMessageRootContract();

        deployL1NullifierContracts();
        deploySharedBridgeContracts();
        deployBridgedStandardERC20Implementation();
        deployBridgedTokenBeacon();
        deployL1NativeTokenVaultImplementation();
        deployL1NativeTokenVaultProxy();
        deployErc20BridgeImplementation();

        deployCTMDeploymentTracker();

        initializeGeneratedData();
        initializeExpectedL2Addresses();

        deployChainTypeManagerContract();
        setChainTypeManagerInValidatorTimelock();

        deployPermanentRollupRestriction();

        deployTransitionaryOwner();

        updateOwners();

        saveOutput(outputPath);
    }

    function run() public {
        console.log("Deploying L1 contracts");
    }

    function provideAcceptOwnershipCalls() public returns (Call[] memory calls) {
        console.log("Providing accept ownership calls");

        calls = new Call[](4);
        calls[0] = Call({
            target: addresses.permanentRollupRestriction,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
        calls[1] = Call({
            target: addresses.validatorTimelock,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
        calls[2] = Call({
            target: addresses.bridges.sharedBridgeProxy,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
        calls[3] = Call({
            target: addresses.bridgehub.ctmDeploymentTrackerProxy,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
    }

    function getOwnerAddress() public returns (address) {
        return config.ownerAddress;
    }

    function _getFacetCutsForDeletion() internal returns (Diamond.FacetCut[] memory facetCuts) {
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

    function _composeUpgradeTx() internal returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransaction({
            // FIXME: dont use hardcoded values
            txType: 254,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(address(L2_COMPLEX_UPGRADER_ADDR))),
            gasLimit: 72_000_000,
            gasPerPubdataByteLimit: 800,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: 25,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            // Note, that the data is empty, it will be fully composed inside the `GatewayUpgrade` contract
            data: new bytes(0),
            signature: new bytes(0),
            // All factory deps should've been published before
            factoryDeps: new uint256[](0),
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }

    function getNewProtocolVersion() public returns (uint256) {
        return 0x1900000000;
    }

    function getOldProtocolDeadline() public returns (uint256) {
        return 7 days;
    }

    function getOldProtocolVersion() public returns (uint256) {
        return 0x1800000002;
    }

    function provideSetNewVersionUpgradeCall() public returns (Call[] memory calls) {
        // Just retrieved it from the contract
        uint256 PREVIOUS_PROTOCOL_VERSION = getOldProtocolVersion();
        uint256 DEADLINE = getOldProtocolDeadline();
        uint256 NEW_PROTOCOL_VERSION = getNewProtocolVersion();
        Call memory call = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(
                ChainTypeManager.setNewVersionUpgrade,
                (getChainUpgradeInfo(), PREVIOUS_PROTOCOL_VERSION, DEADLINE, NEW_PROTOCOL_VERSION)
            ),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = call;
    }

    function getChainUpgradeInfo() public returns (Diamond.DiamondCutData memory upgradeCutData) {
        Diamond.FacetCut[] memory deletedFacets = _getFacetCutsForDeletion();

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](deletedFacets.length + 4);
        for (uint i = 0; i < deletedFacets.length; i++) {
            facetCuts[i] = deletedFacets[i];
        }
        facetCuts[deletedFacets.length] = Diamond.FacetCut({
            facet: addresses.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[deletedFacets.length + 1] = Diamond.FacetCut({
            facet: addresses.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[deletedFacets.length + 2] = Diamond.FacetCut({
            facet: addresses.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[deletedFacets.length + 3] = Diamond.FacetCut({
            facet: addresses.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
        });

        // TODO: we should fill this one up completely, but it is straightforward
        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = new IL2ContractDeployer.ForceDeployment[](
            0
        );
        address ctmDeployer = addresses.bridgehub.ctmDeploymentTrackerProxy;

        GatewayUpgradeEncodedInput memory gateUpgradeInput = GatewayUpgradeEncodedInput({
            baseForceDeployments: baseForceDeployments,
            ctmDeployer: ctmDeployer,
            fixedForceDeploymentsData: generatedData.forceDeploymentsData,
            l2GatewayUpgrade: addresses.expectedL2Addresses.expectedL2GatewayUpgrade,
            oldValidatorTimelock: config.contracts.oldValidatorTimelock,
            newValidatorTimelock: addresses.validatorTimelock
        });

        bytes memory postUpgradeCalldata = abi.encode(gateUpgradeInput);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeUpgradeTx(),
            factoryDeps: new bytes[](0),
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            verifier: addresses.stateTransition.verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: postUpgradeCalldata,
            // FIXME: TBH, I am not sure if even should even put any time there,
            // but we may
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.gatewayUpgrade,
            initCalldata: abi.encodeCall(GatewayUpgrade.upgrade, (proposedUpgrade))
        });
    }

    function getStage2UpgradeCalls() public returns (Call[] memory calls) {
        calls = new Call[](9);

        // We need to firstly update all the contracts
        calls[0] = Call({
            target: config.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(config.contracts.stateTransitionManagerAddress)),
                    addresses.stateTransition.chainTypeManagerImplementation
                )
            ),
            value: 0
        });
        calls[1] = Call({
            target: config.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (
                    ITransparentUpgradeableProxy(payable(config.contracts.bridgehubProxyAddress)),
                    addresses.bridgehub.bridgehubImplementation,
                    abi.encodeCall(Bridgehub.initializeV2, ())
                )
            ),
            value: 0
        });
        calls[2] = Call({
            target: config.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(config.contracts.oldSharedBridgeProxyAddress)),
                    addresses.bridges.l1NullifierImplementation
                )
            ),
            value: 0
        });
        calls[3] = Call({
            target: config.contracts.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(config.contracts.legacyErc20BridgeAddress)),
                    addresses.bridges.erc20BridgeImplementation
                )
            ),
            value: 0
        });

        // Now, updating chain creation params
        calls[4] = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(ChainTypeManager.setChainCreationParams, (prepareNewChainCreationParams())),
            value: 0
        });
        calls[5] = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(ChainTypeManager.setValidatorTimelock, (addresses.validatorTimelock)),
            value: 0
        });

        // Now, we need to update the bridgehub
        calls[6] = Call({
            target: config.contracts.bridgehubProxyAddress,
            data: abi.encodeCall(
                Bridgehub.setAddresses,
                (
                    addresses.bridges.sharedBridgeProxy,
                    CTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy),
                    MessageRoot(addresses.bridgehub.messageRootProxy)
                )
            ),
            value: 0
        });

        // Setting the necessary params for the L1Nullifier contract
        calls[7] = Call({
            target: config.contracts.oldSharedBridgeProxyAddress,
            data: abi.encodeCall(
                L1Nullifier.setL1NativeTokenVault,
                (L1NativeTokenVault(payable(addresses.vaults.l1NativeTokenVaultProxy)))
            ),
            value: 0
        });
        calls[8] = Call({
            target: config.contracts.oldSharedBridgeProxyAddress,
            data: abi.encodeCall(L1Nullifier.setL1AssetRouter, (addresses.bridges.sharedBridgeProxy)),
            value: 0
        });
    }

    function initializeConfig(string memory configPath) internal {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");

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

        config.contracts.stateTransitionManagerAddress = toml.readAddress(
            "$.contracts.state_transition_manager_address"
        );
        config.contracts.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");
        config.contracts.oldSharedBridgeProxyAddress = toml.readAddress("$.contracts.old_shared_bridge_proxy_address");
        config.contracts.transparentProxyAdmin = toml.readAddress("$.contracts.transparent_proxy_admin");
        config.contracts.eraDiamondProxy = toml.readAddress("$.contracts.era_diamond_proxy");
        config.contracts.legacyErc20BridgeAddress = toml.readAddress("$.contracts.legacy_erc20_bridge_address");
        config.contracts.oldValidatorTimelock = toml.readAddress("$.contracts.old_validator_timelock");
        // FIXME: value stored there is incorrect at the moment, figure out the correct value
        config.contracts.blobVersionedHashRetriever = toml.readAddress("$.contracts.blob_versioned_hash_retriever");
        config.contracts.l2BridgeProxyOwnerAddress = toml.readAddress("$.contracts.l2_bridge_proxy_owner_address");
        config.contracts.l2BridgedStandardERC20ProxyOwnerAddress = toml.readAddress(
            "$.contracts.l2_bridged_standard_erc20_proxy_owner_address"
        );

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
    }

    function initializeGeneratedData() internal {
        generatedData.forceDeploymentsData = prepareForceDeploymentsData();
    }

    function initializeExpectedL2Addresses() internal {
        address aliasedGovernance = AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress);

        address expectedL2ProxyAdminDeployer = Utils.getL2AddressViaCreate2Factory(
            bytes32(0),
            L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readProxyAdminDeployerBytecode()),
            abi.encode(aliasedGovernance)
        );
        address expectedL2ProxyAdmin = L2ContractHelper.computeCreate2Address(
            expectedL2ProxyAdminDeployer,
            bytes32(0),
            L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readProxyAdminBytecode()),
            keccak256(hex"")
        );

        address permanentRestrictionImpl = Utils.getL2AddressViaCreate2Factory(
            bytes32(0),
            L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readPermanentRestrictionBytecode()),
            // Note that for L2 deployments the L2AdminFactory is 0.
            abi.encode(L2_BRIDGEHUB_ADDRESS, address(0))
        );

        address permanentRestrictionProxy = Utils.getL2AddressViaCreate2Factory(
            bytes32(0),
            L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecode()),
            abi.encode(
                permanentRestrictionImpl,
                expectedL2ProxyAdmin,
                abi.encodeCall(PermanentRestriction.initialize, (aliasedGovernance))
            )
        );

        address[] memory requiredL2Restrictions = new address[](1);
        requiredL2Restrictions[0] = permanentRestrictionProxy;

        addresses.expectedL2Addresses = ExpectedL2Addresses({
            expectedRollupL2DAValidator: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode()),
                hex""
            ),
            expectedValidiumL2DAValidator: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readValidiumL2DAValidatorBytecode()),
                hex""
            ),
            expectedL2GatewayUpgrade: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readGatewayUpgradeBytecode()),
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
            ),
            expectedL2ProxyAdminDeployer: expectedL2ProxyAdminDeployer,
            expectedL2ProxyAdmin: expectedL2ProxyAdmin,
            expectedL2AdminFactory: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readL2AdminFactoryBytecode()),
                abi.encode(requiredL2Restrictions)
            ),
            expectedL2PermanentRestrictionImpl: permanentRestrictionImpl,
            expectedL2PermanentRestrictionProxy: permanentRestrictionProxy
        });
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

    function deployVerifier() internal {
        bytes memory code;
        if (config.testnetVerifier) {
            code = type(TestnetVerifier).creationCode;
        } else {
            code = type(Verifier).creationCode;
        }
        address contractAddress = deployViaCreate2(code);
        console.log("Verifier deployed at:", contractAddress);
        addresses.stateTransition.verifier = contractAddress;
    }

    function deployDefaultUpgrade() internal {
        address contractAddress = deployViaCreate2(type(DefaultUpgrade).creationCode);
        console.log("DefaultUpgrade deployed at:", contractAddress);
        addresses.stateTransition.defaultUpgrade = contractAddress;
    }

    function deployGenesisUpgrade() internal {
        bytes memory bytecode = abi.encodePacked(type(L1GenesisUpgrade).creationCode);
        address contractAddress = deployViaCreate2(bytecode);
        console.log("GenesisUpgrade deployed at:", contractAddress);
        addresses.stateTransition.genesisUpgrade = contractAddress;
    }

    function deployGatewayUpgrade() internal {
        bytes memory bytecode = abi.encodePacked(type(GatewayUpgrade).creationCode);
        address contractAddress = deployViaCreate2(bytecode);
        console.log("GatewayUpgrade deployed at:", contractAddress);
        addresses.gatewayUpgrade = contractAddress;
    }

    function deployDAValidators() internal {
        address contractAddress = deployViaCreate2(Utils.readRollupDAValidatorBytecode());
        console.log("L1RollupDAValidator deployed at:", contractAddress);
        addresses.daAddresses.l1RollupDAValidator = contractAddress;

        contractAddress = deployViaCreate2(type(ValidiumL1DAValidator).creationCode);
        console.log("L1ValidiumDAValidator deployed at:", contractAddress);
        addresses.daAddresses.l1ValidiumDAValidator = contractAddress;
    }

    function deployPermanentRollupRestriction() internal {
        bytes memory bytecode = abi.encodePacked(
            type(PermanentRestriction).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress, addresses.expectedL2Addresses.expectedL2AdminFactory)
        );
        address implementationAddress = deployViaCreate2(bytecode);

        bytes memory proxyBytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                implementationAddress,
                config.contracts.transparentProxyAdmin,
                abi.encodeCall(PermanentRestriction.initialize, (config.deployerAddress))
            )
        );

        address proxyAddress = deployViaCreate2(proxyBytecode);
        addresses.permanentRollupRestriction = proxyAddress;
        // FIXME: supply restrictions
    }

    function deployValidatorTimelock() internal {
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        bytes memory bytecode = abi.encodePacked(
            type(ValidatorTimelock).creationCode,
            abi.encode(config.deployerAddress, executionDelay, config.eraChainId)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ValidatorTimelock deployed at:", contractAddress);
        addresses.validatorTimelock = contractAddress;
    }

    function deployChainAdmin() internal {
        bytes memory accessControlRestrictionBytecode = abi.encodePacked(
            type(AccessControlRestriction).creationCode,
            abi.encode(uint256(0), config.ownerAddress)
        );

        address accessControlRestriction = deployViaCreate2(accessControlRestrictionBytecode);
        console.log("Access control restriction deployed at:", accessControlRestriction);
        address[] memory restrictions = new address[](1);
        restrictions[0] = accessControlRestriction;
        addresses.accessControlRestrictionAddress = accessControlRestriction;

        bytes memory bytecode = abi.encodePacked(type(ChainAdmin).creationCode, abi.encode(restrictions));
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ChainAdmin deployed at:", contractAddress);
        addresses.chainAdmin = contractAddress;
    }

    function deployBridgehubImplementation() internal {
        bytes memory bridgeHubBytecode = abi.encodePacked(
            type(Bridgehub).creationCode,
            abi.encode(config.l1ChainId, config.ownerAddress, (config.contracts.maxNumberOfChains))
        );
        address bridgehubImplementation = deployViaCreate2(bridgeHubBytecode);
        console.log("Bridgehub Implementation deployed at:", bridgehubImplementation);
        addresses.bridgehub.bridgehubImplementation = bridgehubImplementation;
    }

    function deployMessageRootContract() internal {
        bytes memory messageRootBytecode = abi.encodePacked(
            type(MessageRoot).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress)
        );
        address messageRootImplementation = deployViaCreate2(messageRootBytecode);
        console.log("MessageRoot Implementation deployed at:", messageRootImplementation);
        addresses.bridgehub.messageRootImplementation = messageRootImplementation;

        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                messageRootImplementation,
                config.contracts.transparentProxyAdmin,
                abi.encodeCall(MessageRoot.initialize, ())
            )
        );
        address messageRootProxy = deployViaCreate2(bytecode);
        console.log("Message Root Proxy deployed at:", messageRootProxy);
        addresses.bridgehub.messageRootProxy = messageRootProxy;
    }

    function deployCTMDeploymentTracker() internal {
        bytes memory ctmDTBytecode = abi.encodePacked(
            type(CTMDeploymentTracker).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress, addresses.bridges.sharedBridgeProxy)
        );
        address ctmDTImplementation = deployViaCreate2(ctmDTBytecode);
        console.log("CTM Deployment Tracker Implementation deployed at:", ctmDTImplementation);
        addresses.bridgehub.ctmDeploymentTrackerImplementation = ctmDTImplementation;

        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                ctmDTImplementation,
                config.contracts.transparentProxyAdmin,
                abi.encodeCall(CTMDeploymentTracker.initialize, (config.deployerAddress))
            )
        );
        address ctmDTProxy = deployViaCreate2(bytecode);
        console.log("CTM Deployment Tracker Proxy deployed at:", ctmDTProxy);
        addresses.bridgehub.ctmDeploymentTrackerProxy = ctmDTProxy;
    }

    function deployChainTypeManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployChainTypeManagerImplementation();
        // registerChainTypeManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        address executorFacet = deployViaCreate2(type(ExecutorFacet).creationCode);
        console.log("ExecutorFacet deployed at:", executorFacet);
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(
            abi.encodePacked(type(AdminFacet).creationCode, abi.encode(config.l1ChainId))
        );
        console.log("AdminFacet deployed at:", adminFacet);
        addresses.stateTransition.adminFacet = adminFacet;

        address mailboxFacet = deployViaCreate2(
            abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(config.eraChainId, config.l1ChainId))
        );
        console.log("MailboxFacet deployed at:", mailboxFacet);
        addresses.stateTransition.mailboxFacet = mailboxFacet;

        address gettersFacet = deployViaCreate2(type(GettersFacet).creationCode);
        console.log("GettersFacet deployed at:", gettersFacet);
        addresses.stateTransition.gettersFacet = gettersFacet;

        address diamondInit = deployViaCreate2(type(DiamondInit).creationCode);
        console.log("DiamondInit deployed at:", diamondInit);
        addresses.stateTransition.diamondInit = diamondInit;
    }

    function deployChainTypeManagerImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(ChainTypeManager).creationCode,
            abi.encode(config.contracts.bridgehubProxyAddress)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ChainTypeManagerImplementation deployed at:", contractAddress);
        addresses.stateTransition.chainTypeManagerImplementation = contractAddress;
    }

    function setChainTypeManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        vm.broadcast(msg.sender);
        validatorTimelock.setChainTypeManager(IChainTypeManager(config.contracts.stateTransitionManagerAddress));
        console.log("ChainTypeManager set in ValidatorTimelock");
    }

    function deploySharedBridgeContracts() internal {
        deploySharedBridgeImplementation();
        deploySharedBridgeProxy();
        setL1LegacyBridge();
    }

    function deployL1NullifierContracts() internal {
        deployL1NullifierImplementation();
    }

    function deployL1NullifierImplementation() internal {
        // TODO(EVM-743): allow non-dev nullifier in the local deployment
        bytes memory bytecode = abi.encodePacked(
            type(L1NullifierDev).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(config.contracts.bridgehubProxyAddress, config.eraChainId, config.contracts.eraDiamondProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NullifierImplementation deployed at:", contractAddress);
        addresses.bridges.l1NullifierImplementation = contractAddress;
    }

    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1AssetRouter).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                config.contracts.bridgehubProxyAddress,
                config.contracts.oldSharedBridgeProxyAddress,
                config.eraChainId,
                config.contracts.eraDiamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeImplementation deployed at:", contractAddress);
        addresses.bridges.sharedBridgeImplementation = contractAddress;
    }

    function deploySharedBridgeProxy() internal {
        bytes memory initCalldata = abi.encodeCall(L1AssetRouter.initialize, (config.deployerAddress));
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                addresses.bridges.sharedBridgeImplementation,
                config.contracts.transparentProxyAdmin,
                initCalldata
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeProxy deployed at:", contractAddress);
        addresses.bridges.sharedBridgeProxy = contractAddress;
    }

    function setL1LegacyBridge() internal {
        vm.broadcast(msg.sender);
        L1AssetRouter(addresses.bridges.sharedBridgeProxy).setL1Erc20Bridge(
            L1ERC20Bridge(config.contracts.legacyErc20BridgeAddress)
        );
    }

    function deployErc20BridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1ERC20Bridge).creationCode,
            abi.encode(
                config.contracts.oldSharedBridgeProxyAddress,
                addresses.bridges.sharedBridgeProxy,
                addresses.vaults.l1NativeTokenVaultProxy,
                config.eraChainId
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Erc20BridgeImplementation deployed at:", contractAddress);
        addresses.bridges.erc20BridgeImplementation = contractAddress;
    }

    function deployBridgedStandardERC20Implementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(BridgedStandardERC20).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode()
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("BridgedStandardERC20Implementation deployed at:", contractAddress);
        addresses.bridges.bridgedStandardERC20Implementation = contractAddress;
    }

    function deployBridgedTokenBeacon() internal {
        bytes memory bytecode = abi.encodePacked(
            type(UpgradeableBeacon).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(addresses.bridges.bridgedStandardERC20Implementation)
        );
        UpgradeableBeacon beacon = new UpgradeableBeacon(addresses.bridges.bridgedStandardERC20Implementation);
        address contractAddress = address(beacon);
        beacon.transferOwnership(config.ownerAddress);
        console.log("BridgedTokenBeacon deployed at:", contractAddress);
        addresses.bridges.bridgedTokenBeacon = contractAddress;
    }

    function deployL1NativeTokenVaultImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1NativeTokenVault).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                addresses.bridges.sharedBridgeProxy,
                config.eraChainId,
                config.contracts.oldSharedBridgeProxyAddress
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NativeTokenVaultImplementation deployed at:", contractAddress);
        addresses.vaults.l1NativeTokenVaultImplementation = contractAddress;
    }

    function deployL1NativeTokenVaultProxy() internal {
        bytes memory initCalldata = abi.encodeCall(
            L1NativeTokenVault.initialize,
            (config.ownerAddress, addresses.bridges.bridgedTokenBeacon)
        );
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                addresses.vaults.l1NativeTokenVaultImplementation,
                config.contracts.transparentProxyAdmin,
                initCalldata
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("L1NativeTokenVaultProxy deployed at:", contractAddress);
        addresses.vaults.l1NativeTokenVaultProxy = contractAddress;

        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.sharedBridgeProxy);
        IL1Nullifier l1Nullifier = IL1Nullifier(config.contracts.oldSharedBridgeProxyAddress);
        // Ownable ownable = Ownable(addresses.bridges.sharedBridgeProxy);

        vm.broadcast(msg.sender);
        sharedBridge.setNativeTokenVault(INativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerEthToken();
    }

    function deployTransitionaryOwner() internal {
        bytes memory bytecode = abi.encodePacked(
            type(TransitionaryOwner).creationCode,
            abi.encode(config.ownerAddress)
        );

        addresses.transitionaryOwner = deployViaCreate2(bytecode);
    }

    function _moveGovernanceToOwner(address target) internal {
        Ownable2StepUpgradeable(target).transferOwnership(addresses.transitionaryOwner);
        TransitionaryOwner(addresses.transitionaryOwner).claimOwnershipAndGiveToGovernance(target);
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        // Note, that it will take some time for the governance to sign the "acceptOwnership" transaction,
        // in order to avoid any possibility of the front-run, we will temporarily give the ownership to the
        // contract that can only transfer ownership to the governance.
        _moveGovernanceToOwner(addresses.validatorTimelock);
        _moveGovernanceToOwner(addresses.bridges.sharedBridgeProxy);
        _moveGovernanceToOwner(addresses.bridgehub.ctmDeploymentTrackerProxy);
        _moveGovernanceToOwner(addresses.permanentRollupRestriction);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function prepareNewChainCreationParams() internal returns (ChainCreationParams memory chainCreationParams) {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
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

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(addresses.stateTransition.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: config.contracts.bootloaderHash,
            l2DefaultAccountBytecodeHash: config.contracts.defaultAAHash,
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            feeParams: feeParams,
            blobVersionedHashRetriever: config.contracts.blobVersionedHashRetriever
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        chainCreationParams = ChainCreationParams({
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: generatedData.forceDeploymentsData
        });
    }

    function saveOutput(string memory outputPath) internal {
        vm.serializeAddress("bridgehub", "bridgehub_implementation_addr", addresses.bridgehub.bridgehubImplementation);
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            addresses.bridgehub.ctmDeploymentTrackerImplementation
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
            "shared_bridge_implementation_addr",
            addresses.bridges.sharedBridgeImplementation
        );
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            addresses.bridges.sharedBridgeProxy
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
        vm.serializeAddress(
            "contracts_config",
            "expected_l2_gateway_upgrade",
            addresses.expectedL2Addresses.expectedL2GatewayUpgrade
        );
        vm.serializeBytes("contracts_config", "diamond_cut_data", generatedData.diamondCutData);

        string memory contractsConfig = vm.serializeBytes(
            "contracts_config",
            "force_deployments_data",
            generatedData.forceDeploymentsData
        );

        vm.serializeAddress("deployed_addresses", "validator_timelock_addr", addresses.validatorTimelock);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeAddress("deployed_addresses", "permanent_rollup_restriction", addresses.permanentRollupRestriction);
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

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            addresses.vaults.l1NativeTokenVaultProxy
        );

        vm.serializeAddress("root", "create2_factory_addr", addresses.create2Factory);
        vm.serializeBytes32("root", "create2_factory_salt", config.contracts.create2FactorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "contracts_config", contractsConfig);
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.contracts.create2FactorySalt, addresses.create2Factory);
    }

    function prepareForceDeploymentsData() internal view returns (bytes memory) {
        require(config.ownerAddress != address(0), "owner not set");

        FixedForceDeploymentsData memory data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: addresses.bridges.sharedBridgeProxy,
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
            l2BridgeProxyOwnerAddress: config.contracts.l2BridgeProxyOwnerAddress,
            l2BridgedStandardERC20ProxyOwnerAddress: config.contracts.l2BridgedStandardERC20ProxyOwnerAddress
        });

        return abi.encode(data);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
