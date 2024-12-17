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
        address validatorTimelock;
        address gatewayUpgrade;
        address create2Factory;
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
    struct L1NativeTokenVaultAddresses {
        address l1NativeTokenVaultImplementation;
        address l1NativeTokenVaultProxy;
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
        // This is the address of the ecosystem admin.
        // Note, that it is not the owner, but rather the address that is responsible
        // for facilitating partially trusted, but not critical tasks.
        address ecosystemAdminAddress;
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
    }

    struct TokensConfig {
        address tokenWethAddress;
    }

    Config internal config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    uint256[] factoryDepsHashes;

    struct CachedBytecodeHashes {
        bytes32 sharedL2LegacyBridgeBytecodeHash;
        bytes32 erc20StandardImplBytecodeHash;
        bytes32 rollupL2DAValidatorBytecodeHash;
        bytes32 validiumL2DAValidatorBytecodeHash;
        bytes32 transparentUpgradableProxyBytecodeHash;
    }

    CachedBytecodeHashes internal cachedBytecodeHashes;

    function prepareEcosystemContracts(string memory configPath, string memory outputPath) public {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(configPath);

        instantiateCreate2Factory();

        deployBytecodesSupplier();
        publishBytecodes();
        initializeExpectedL2Addresses();

        deployVerifier();
        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployGatewayUpgrade();

        deployDAValidators();
        deployValidatorTimelock();

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

        // Important, this must come after the initializeExpectedL2Addresses
        initializeGeneratedData();

        deployChainTypeManagerContract();
        setChainTypeManagerInValidatorTimelock();

        deployTransitionaryOwner();
        deployL2WrappedBaseTokenStore();
        deployGovernanceUpgradeTimer();

        updateOwners();

        saveOutput(outputPath);
    }

    function run() public {
        prepareEcosystemContracts(
            "/script-config/gateway-upgrade-ecosystem.toml",
            "/script-out/gateway-upgrade-ecosystem.toml"
        );
    }

    function provideAcceptOwnershipCalls() public returns (Call[] memory calls) {
        console.log("Providing accept ownership calls");

        calls = new Call[](4);
        calls[0] = Call({
            target: addresses.validatorTimelock,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
        calls[1] = Call({
            target: addresses.bridges.sharedBridgeProxy,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
        calls[2] = Call({
            target: addresses.bridgehub.ctmDeploymentTrackerProxy,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ()),
            value: 0
        });
        calls[3] = Call({
            target: addresses.daAddresses.rollupDAManager,
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
            // TODO: dont use hardcoded values
            txType: 254,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            // Note, that we actually do force deployments to the ContractDeployer and not complex upgrader.
            // The implementation of the ComplexUpgrader will be deployed during one of the force deployments.
            to: uint256(uint160(address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR))),
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
            factoryDeps: factoryDepsHashes,
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
        // Note, that it is this way by design, on stage2 it
        // will be set to 0
        return type(uint256).max;
    }

    function getOldProtocolVersion() public returns (uint256) {
        return 0x1800000002;
    }

    function provideSetNewVersionUpgradeCall() public returns (Call[] memory calls) {
        // Just retrieved it from the contract
        uint256 PREVIOUS_PROTOCOL_VERSION = getOldProtocolVersion();
        uint256 DEADLINE = getOldProtocolDeadline();
        uint256 NEW_PROTOCOL_VERSION = getNewProtocolVersion();
        Call memory ctmCall = Call({
            target: config.contracts.stateTransitionManagerAddress,
            data: abi.encodeCall(
                ChainTypeManager.setNewVersionUpgrade,
                (getChainUpgradeInfo(), PREVIOUS_PROTOCOL_VERSION, DEADLINE, NEW_PROTOCOL_VERSION)
            ),
            value: 0
        });

        // The call that will start the timer till the end of the upgrade.
        Call memory timerCall = Call({
            target: addresses.upgradeTimer,
            data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()),
            value: 0
        });

        calls = new Call[](2);
        calls[0] = ctmCall;
        calls[1] = timerCall;
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

        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments();

        // This upgrade has complex upgrade. We do not know whether its implementation has been deployed.
        // We will do the following trick:
        // - Deploy the upgrade implementation into the address of the complex upgrader. And execute the upgrade inside the constructor.
        // - Deploy back the original bytecode.
        //
        // Also, we need to predeploy the bridges implementation
        IL2ContractDeployer.ForceDeployment[]
            memory additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](6);
        additionalForceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: cachedBytecodeHashes.sharedL2LegacyBridgeBytecodeHash,
            newAddress: addresses.expectedL2Addresses.l2SharedBridgeLegacyImpl,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[1] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: cachedBytecodeHashes.erc20StandardImplBytecodeHash,
            newAddress: addresses.expectedL2Addresses.l2BridgedStandardERC20Impl,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[2] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: cachedBytecodeHashes.rollupL2DAValidatorBytecodeHash,
            newAddress: addresses.expectedL2Addresses.expectedRollupL2DAValidator,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[3] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: cachedBytecodeHashes.validiumL2DAValidatorBytecodeHash,
            newAddress: addresses.expectedL2Addresses.expectedValidiumL2DAValidator,
            callConstructor: true,
            value: 0,
            input: ""
        });
        additionalForceDeployments[4] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readGatewayUpgradeBytecode()),
            newAddress: L2_COMPLEX_UPGRADER_ADDR,
            callConstructor: true,
            value: 0,
            input: ""
        });
        // Getting the contract back to normal
        additionalForceDeployments[5] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(Utils.readSystemContractsBytecode("ComplexUpgrader")),
            newAddress: L2_COMPLEX_UPGRADER_ADDR,
            callConstructor: false,
            value: 0,
            input: ""
        });

        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = SystemContractsProcessing.mergeForceDeployments(
            baseForceDeployments,
            additionalForceDeployments
        );

        address ctmDeployer = addresses.bridgehub.ctmDeploymentTrackerProxy;

        GatewayUpgradeEncodedInput memory gateUpgradeInput = GatewayUpgradeEncodedInput({
            forceDeployments: forceDeployments,
            l2GatewayUpgradePosition: forceDeployments.length - 2,
            ctmDeployer: ctmDeployer,
            fixedForceDeploymentsData: generatedData.forceDeploymentsData,
            oldValidatorTimelock: config.contracts.oldValidatorTimelock,
            newValidatorTimelock: addresses.validatorTimelock,
            wrappedBaseTokenStore: addresses.l2WrappedBaseTokenStore
        });

        bytes memory postUpgradeCalldata = abi.encode(gateUpgradeInput);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeUpgradeTx(),
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            verifier: addresses.stateTransition.verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: postUpgradeCalldata,
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.gatewayUpgrade,
            initCalldata: abi.encodeCall(GatewayUpgrade.upgrade, (proposedUpgrade))
        });
    }

    function getEcosystemAdmin() external returns (address) {
        return config.ecosystemAdminAddress;
    }

    function getStage1UpgradeCalls() public returns (Call[] memory calls) {
        // Stage 1 of the upgrade:
        // - accept all the ownerships of the contracts
        // - set the new upgrade data for chains + update validator timelock.
        calls = mergeCalls(provideAcceptOwnershipCalls(), provideSetNewVersionUpgradeCall());
    }

    function getStage2UpgradeCalls() public returns (Call[] memory calls) {
        calls = new Call[](11);

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
                    // Note, that we do not need to run the initializer
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
        calls[9] = Call({
            target: config.contracts.stateTransitionManagerAddress,
            // Making the old protocol version no longer invalid
            data: abi.encodeCall(ChainTypeManager.setProtocolVersionDeadline, (getOldProtocolVersion(), 0)),
            value: 0
        });
        calls[10] = Call({
            target: addresses.upgradeTimer,
            // Double checking that the deadline has passed.
            data: abi.encodeCall(GovernanceUpgradeTimer.checkDeadline, ()),
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
        // TODO: value stored there is incorrect at the moment, figure out the correct value
        config.contracts.blobVersionedHashRetriever = toml.readAddress("$.contracts.blob_versioned_hash_retriever");

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");

        // TODO: maybe receive the address from the config + cross check
        config.ecosystemAdminAddress = Bridgehub(config.contracts.bridgehubProxyAddress).admin();
    }

    function initializeGeneratedData() internal {
        generatedData.forceDeploymentsData = prepareForceDeploymentsData();
    }

    function initializeExpectedL2Addresses() internal {
        address aliasedGovernance = AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress);

        addresses.expectedL2Addresses = ExpectedL2Addresses({
            expectedRollupL2DAValidator: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                cachedBytecodeHashes.rollupL2DAValidatorBytecodeHash,
                hex""
            ),
            expectedValidiumL2DAValidator: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                cachedBytecodeHashes.validiumL2DAValidatorBytecodeHash,
                hex""
            ),
            l2SharedBridgeLegacyImpl: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                cachedBytecodeHashes.sharedL2LegacyBridgeBytecodeHash,
                hex""
            ),
            l2BridgedStandardERC20Impl: Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                cachedBytecodeHashes.erc20StandardImplBytecodeHash,
                hex""
            )
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

    function deployBytecodesSupplier() internal {
        address contractAddress = deployViaCreate2(type(BytecodesSupplier).creationCode);
        console.log("BytecodesSupplier deployed at:", contractAddress);
        addresses.bytecodesSupplier = contractAddress;
    }

    function getFullListOfFactoryDependencies() internal returns (bytes[] memory factoryDeps) {
        bytes[] memory basicDependencies = SystemContractsProcessing.getBaseListOfDependencies();

        // This upgrade will also require to publish:
        // - L2GatewayUpgrade
        // - new L2 shared bridge legacy implementation
        // - new bridged erc20 token implementation
        //
        // Also, not strictly necessary, but better for consistency with the new chains:
        // - UpgradeableBeacon
        // - BeaconProxy

        bytes[] memory upgradeSpecificDependencies = new bytes[](8);
        upgradeSpecificDependencies[0] = L2ContractsBytecodesLib.readGatewayUpgradeBytecode();
        upgradeSpecificDependencies[1] = L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode();
        upgradeSpecificDependencies[2] = L2ContractsBytecodesLib.readStandardERC20Bytecode();

        upgradeSpecificDependencies[3] = L2ContractsBytecodesLib.readUpgradeableBeaconBytecode();
        upgradeSpecificDependencies[4] = L2ContractsBytecodesLib.readBeaconProxyBytecode();

        // We do not know whether the chain will be a rollup or a validium, just in case, we'll deploy
        // both of the validators.
        upgradeSpecificDependencies[5] = L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode();
        upgradeSpecificDependencies[6] = L2ContractsBytecodesLib.readValidiumL2DAValidatorBytecode();

        upgradeSpecificDependencies[7] = L2ContractsBytecodesLib
            .readTransparentUpgradeableProxyBytecodeFromSystemContracts();

        cachedBytecodeHashes = CachedBytecodeHashes({
            sharedL2LegacyBridgeBytecodeHash: L2ContractHelper.hashL2Bytecode(upgradeSpecificDependencies[1]),
            erc20StandardImplBytecodeHash: L2ContractHelper.hashL2Bytecode(upgradeSpecificDependencies[2]),
            rollupL2DAValidatorBytecodeHash: L2ContractHelper.hashL2Bytecode(upgradeSpecificDependencies[5]),
            validiumL2DAValidatorBytecodeHash: L2ContractHelper.hashL2Bytecode(upgradeSpecificDependencies[6]),
            transparentUpgradableProxyBytecodeHash: L2ContractHelper.hashL2Bytecode(upgradeSpecificDependencies[7])
        });

        factoryDeps = SystemContractsProcessing.mergeBytesArrays(basicDependencies, upgradeSpecificDependencies);
        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }

    function publishBytecodes() internal {
        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        BytecodePublisher.publishBytecodesInBatches(BytecodesSupplier(addresses.bytecodesSupplier), allDeps);

        uint256[] memory factoryDeps = new uint256[](allDeps.length);

        require(factoryDeps.length <= 64, "Too many deps");

        for (uint256 i = 0; i < allDeps.length; i++) {
            factoryDeps[i] = uint256(L2ContractHelper.hashL2Bytecode(allDeps[i]));
        }

        // Double check for consistency:
        require(bytes32(factoryDeps[0]) == config.contracts.bootloaderHash, "bootloader hash factory dep mismatch");
        require(bytes32(factoryDeps[1]) == config.contracts.defaultAAHash, "default aa hash factory dep mismatch");

        factoryDepsHashes = factoryDeps;
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
        vm.broadcast(msg.sender);
        address rollupDAManager = address(new RollupDAManager());
        addresses.daAddresses.rollupDAManager = rollupDAManager;

        address rollupDAValidator = deployViaCreate2(Utils.readRollupDAValidatorBytecode());
        console.log("L1RollupDAValidator deployed at:", rollupDAValidator);
        addresses.daAddresses.l1RollupDAValidator = rollupDAValidator;

        address validiumDAValidator = deployViaCreate2(type(ValidiumL1DAValidator).creationCode);
        console.log("L1ValidiumDAValidator deployed at:", validiumDAValidator);
        addresses.daAddresses.l1ValidiumDAValidator = validiumDAValidator;

        vm.broadcast(msg.sender);
        RollupDAManager(rollupDAManager).updateDAPair(
            address(rollupDAValidator),
            addresses.expectedL2Addresses.expectedRollupL2DAValidator,
            true
        );
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
    }

    function deployStateTransitionDiamondFacets() internal {
        address executorFacet = deployViaCreate2(
            abi.encodePacked(type(ExecutorFacet).creationCode, abi.encode(config.l1ChainId))
        );
        console.log("ExecutorFacet deployed at:", executorFacet);
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(
            abi.encodePacked(
                type(AdminFacet).creationCode,
                abi.encode(config.l1ChainId, addresses.daAddresses.rollupDAManager)
            )
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
        vm.startBroadcast(config.deployerAddress);
        L1AssetRouter(addresses.bridges.sharedBridgeProxy).setL1Erc20Bridge(
            L1ERC20Bridge(config.contracts.legacyErc20BridgeAddress)
        );
        vm.stopBroadcast();
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
        // bytes memory bytecode = abi.encodePacked(
        //     type(UpgradeableBeacon).creationCode,
        //     // solhint-disable-next-line func-named-parameters
        //     abi.encode(addresses.bridges.bridgedStandardERC20Implementation)
        // );

        // Note, that the `msg.sender` will be set as the owner.
        // This means that we can not use a naive create2factory. It may be replaced
        // with a more advanced one, but CREATE from a hot wallet is fine too.
        vm.startBroadcast(msg.sender);
        UpgradeableBeacon beacon = new UpgradeableBeacon(addresses.bridges.bridgedStandardERC20Implementation);
        beacon.transferOwnership(config.ownerAddress);
        vm.stopBroadcast();
        address contractAddress = address(beacon);
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

    function deployGovernanceUpgradeTimer() internal {
        // Needed for easy server testing, in reality it will be different
        uint256 INITIAL_DELAY = 0;

        uint256 MAX_ADDITIONAL_DELAY = 2 weeks;

        // It may make sense to have a separate admin there, but
        // using the same as bridgehub is just as fine.
        address bridgehubAdmin = Bridgehub(config.contracts.bridgehubProxyAddress).admin();

        bytes memory bytecode = abi.encodePacked(
            type(GovernanceUpgradeTimer).creationCode,
            abi.encode(INITIAL_DELAY, MAX_ADDITIONAL_DELAY, config.ownerAddress, config.ecosystemAdminAddress)
        );

        addresses.upgradeTimer = deployViaCreate2(bytecode);
    }

    function deployL2WrappedBaseTokenStore() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L2WrappedBaseTokenStore).creationCode,
            abi.encode(config.ownerAddress, config.ecosystemAdminAddress)
        );

        addresses.l2WrappedBaseTokenStore = deployViaCreate2(bytecode);
    }

    function _moveGovernanceToOwner(address target) internal {
        Ownable2StepUpgradeable(target).transferOwnership(addresses.transitionaryOwner);
        TransitionaryOwner(addresses.transitionaryOwner).claimOwnershipAndGiveToGovernance(target);
    }

    function _moveGovernanceToEcosystemAdmin(address target) internal {
        // Is agile enough to accept ownership quickly `config.ecosystemAdminAddress`
        Ownable2StepUpgradeable(target).transferOwnership(config.ecosystemAdminAddress);
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        // Note, that it will take some time for the governance to sign the "acceptOwnership" transaction,
        // in order to avoid any possibility of the front-run, we will temporarily give the ownership to the
        // contract that can only transfer ownership to the governance.
        _moveGovernanceToOwner(addresses.validatorTimelock);
        _moveGovernanceToOwner(addresses.bridges.sharedBridgeProxy);
        _moveGovernanceToOwner(addresses.bridgehub.ctmDeploymentTrackerProxy);
        console.log("hi");
        _moveGovernanceToOwner(addresses.daAddresses.rollupDAManager);

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
        vm.serializeAddress("deployed_addresses", "l1_bytecodes_supplier_addr", addresses.bytecodesSupplier);

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

        vm.serializeBytes("root", "governance_stage1_calls", abi.encode(getStage1UpgradeCalls()));
        vm.serializeBytes("root", "governance_stage2_calls", abi.encode(getStage2UpgradeCalls()));
        vm.serializeBytes("root", "chain_upgrade_diamond_cut", abi.encode(getChainUpgradeInfo()));

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
            l2BridgedStandardERC20Impl: addresses.expectedL2Addresses.l2BridgedStandardERC20Impl
        });

        return abi.encode(data);
    }

    function mergeCalls(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory result) {
        result = new Call[](a.length + b.length);
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
