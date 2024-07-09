// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {_DeployL1Script} from "./_DeployL1.s.sol";

contract DeployL1Script is _DeployL1Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // solhint-disable-next-line gas-struct-packing
    struct DeployedAddresses {
        BridgehubDeployedAddresses bridgehub;
        StateTransitionDeployedAddresses stateTransition;
        BridgesDeployedAddresses bridges;
        address transparentProxyAdmin;
        address governance;
        address chainAdmin;
        address blobVersionedHashRetriever;
        address validatorTimelock;
        address create2Factory;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address bridgehubProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct StateTransitionDeployedAddresses {
        address stateTransitionProxy;
        address stateTransitionImplementation;
        address verifier;
        address adminFacet;
        address mailboxFacet;
        address executorFacet;
        address gettersFacet;
        address diamondInit;
        address genesisUpgrade;
        address defaultUpgrade;
        address diamondProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address erc20BridgeProxy;
        address sharedBridgeImplementation;
        address sharedBridgeProxy;
    }

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 l1ChainId;
        uint256 eraChainId;
        address deployerAddress;
        address ownerAddress;
        bool testnetVerifier;
        ContractsConfig contracts;
        TokensConfig tokens;
    }

    // solhint-disable-next-line gas-struct-packing
    struct ContractsConfig {
        bytes32 create2FactorySalt;
        address create2FactoryAddr;
        address multicall3Addr;
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
        address governanceSecurityCouncilAddress;
        uint256 governanceMinDelay;
        uint256 maxNumberOfChains;
        bytes diamondCutData;
        bytes32 bootloaderHash;
        bytes32 defaultAAHash;
    }

    struct TokensConfig {
        address tokenWethAddress;
    }

    Config internal config;
    DeployedAddresses internal addresses;

    function run() public {
        console.log("Deploying L1 contracts");

        initializeConfig();

        instantiateCreate2Factory();
        deployIfNeededMulticall3();

        deployVerifier();

        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployValidatorTimelock();

        deployGovernance();
        deployChainAdmin();
        deployTransparentProxyAdmin();
        deployBridgehubContract();
        deployBlobVersionedHashRetriever();
        deployStateTransitionManagerContract();
        setStateTransitionManagerInValidatorTimelock();

        deployDiamondProxy();

        deploySharedBridgeContracts();
        deployErc20BridgeImplementation();
        deployErc20BridgeProxy();
        updateSharedBridge();

        updateOwners();

        saveOutput();
    }

    function initializeConfig() internal {
        _initializeConfig();
    }

    function instantiateCreate2Factory() internal {
        _instantiateCreate2Factory();
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on public networks
        _deployIfNeededMulticall3();
    }

    function deployVerifier() internal {
        _deployVerifier();
    }

    function deployDefaultUpgrade() internal {
        _deployDefaultUpgrade();
    }

    function deployGenesisUpgrade() internal {
        _deployGenesisUpgrade();
    }

    function deployValidatorTimelock() internal {
        _deployValidatorTimelock();
    }

    function deployGovernance() internal {
        _deployGovernance();
    }

    function deployChainAdmin() internal {
        bytes memory accessControlRestrictionBytecode = abi.encodePacked(
            type(ChainAdmin).creationCode,
            abi.encode(uint256(0), config.ownerAddress)
        );

        address accessControlRestriction = deployViaCreate2(accessControlRestrictionBytecode);
        console.log("Access control restriction deployed at:", accessControlRestriction);
        address[] memory restrictions = new address[](1);
        restrictions[0] = accessControlRestriction;

        bytes memory bytecode = abi.encodePacked(type(ChainAdmin).creationCode, abi.encode(restrictions));
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ChainAdmin deployed at:", contractAddress);
        addresses.chainAdmin = contractAddress;
    }

    function deployTransparentProxyAdmin() internal {
        vm.startBroadcast(msg.sender);
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(addresses.governance);
        vm.stopBroadcast();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        addresses.transparentProxyAdmin = address(proxyAdmin);
    }

    function deployBridgehubContract() internal {
        _deployBridgehubContract();
    }

    function deployBlobVersionedHashRetriever() internal {
        // solc contracts/state-transition/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
        _deployBlobVersionedHashRetriever();
    }

    function deployStateTransitionManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployStateTransitionManagerImplementation();
        deployStateTransitionManagerProxy();
        registerStateTransitionManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        _deployStateTransitionDiamondFacets();
    }

    function deployStateTransitionManagerImplementation() internal {
        _deployStateTransitionManagerImplementation();
    }

    function deployStateTransitionManagerProxy() internal {
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
            blobVersionedHashRetriever: addresses.blobVersionedHashRetriever
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        config.contracts.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: config.contracts.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            diamondCut: diamondCut
        });

        StateTransitionManagerInitializeData memory diamondInitData = StateTransitionManagerInitializeData({
            owner: msg.sender,
            validatorTimelock: addresses.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: config.contracts.latestProtocolVersion
        });

        address contractAddress = deployViaCreate2(
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    addresses.stateTransition.stateTransitionImplementation,
                    addresses.transparentProxyAdmin,
                    abi.encodeCall(StateTransitionManager.initialize, (diamondInitData))
                )
            )
        );
        console.log("StateTransitionManagerProxy deployed at:", contractAddress);
        addresses.stateTransition.stateTransitionProxy = contractAddress;
    }

    function registerStateTransitionManager() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.broadcast(msg.sender);
        bridgehub.addStateTransitionManager(addresses.stateTransition.stateTransitionProxy);
        console.log("StateTransitionManager registered");
    }

    function setStateTransitionManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        vm.broadcast(msg.sender);
        validatorTimelock.setStateTransitionManager(
            IStateTransitionManager(addresses.stateTransition.stateTransitionProxy)
        );
        console.log("StateTransitionManager set in ValidatorTimelock");
    }

    function deployDiamondProxy() internal {
        _deployDiamondProxy();
    }

    function deploySharedBridgeContracts() internal {
        deploySharedBridgeImplementation();
        deploySharedBridgeProxy();
        registerSharedBridge();
    }

    function deploySharedBridgeImplementation() internal {
        _deploySharedBridgeImplementation();
    }

    function deploySharedBridgeProxy() internal {
        _deploySharedBridgeProxy();
    }

    function registerSharedBridge() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addToken(ADDRESS_ONE);
        bridgehub.setSharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function deployErc20BridgeImplementation() internal {
        _deployErc20BridgeImplementation();
    }

    function deployErc20BridgeProxy() internal {
        _deployErc20BridgeProxy();
    }

    function updateSharedBridge() internal {
        L1SharedBridge sharedBridge = L1SharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(addresses.bridges.erc20BridgeProxy);
        console.log("SharedBridge updated with ERC20Bridge address");
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        bridgehub.transferOwnership(addresses.governance);

        L1SharedBridge sharedBridge = L1SharedBridge(addresses.bridges.sharedBridgeProxy);
        sharedBridge.transferOwnership(addresses.governance);

        StateTransitionManager stm = StateTransitionManager(addresses.stateTransition.stateTransitionProxy);
        stm.transferOwnership(addresses.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput() internal {
        _saveOutput();
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return _deployViaCreate2(_bytecode);
    }
}
