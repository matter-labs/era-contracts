// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {SingletonFactory} from "contracts/dev-contracts/SingletonFactory.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData} from "contracts/state-transition/IStateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeData as DiamondInitInitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";

contract DeployL1Script is Script {
    struct DeployedAddresses {
        BridgehubDeployedAddresses bridgehub;
        StateTransitionDeployedAddresses stateTransition;
        BridgesDeployedAddresses bridges;
        address baseToken;
        address transparentProxyAdmin;
        address governance;
        address blobVersionedHashRetriever;
        address validatorTimelock;
        address create2Factory;
    }

    struct BridgehubDeployedAddresses {
        address bridgehubImplementation;
        address bridgehubProxy;
    }

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
        address diamondUpgradeInit;
        address defaultUpgrade;
        address diamondProxy;
    }

    struct BridgesDeployedAddresses {
        address erc20BridgeImplementation;
        address erc20BridgeProxy;
        address sharedBridgeImplementation;
        address sharedBridgeProxy;
    }

    uint256 deployerPrivateKey;
    address deployerAddress;
    bytes32 create2Salt;
    uint256 chainId;
    string network;

    DeployedAddresses addresses;

    function run() public {
        console.log("Deploying L1 contracts");

        initializeConfig();

        deployOrInstantiateCreate2Factory();
        deployIfNeededMulticall3();

        deployVerifier();

        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployValidatorTimelock();

        deployGovernance();
        deployTransparentProxyAdmin();
        deployBridgehubContract();
        deployBlobVersionedHashRetriever();
        deployStateTransitionManagerContract();
        setStateTransitionManagerInValidatorTimelock();

        deployErc20BridgeProxy();
        deploySharedBridgeContracts();
        deployErc20BridgeImplementation();
        upgradeL1Erc20Bridge();
    }

    function initializeConfig() internal {
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployerAddress = vm.addr(deployerPrivateKey);
        console.log("Using deployer wallet:", deployerAddress);

        uint256 gasPrice = vm.envOr("GAS_PRICE", uint256(0));
        if (gasPrice != 0) {
            vm.txGasPrice(gasPrice);
            console.log("Using gas price:", gasPrice);
        } else {
            console.log("Using provider's gas price");
        }

        chainId = vm.envUint("CHAIN_ID");
        create2Salt = vm.envBytes32("CONTRACTS_CREATE2_FACTORY_SALT");
        network = vm.envString("CHAIN_ETH_NETWORK");
    }

    function deployOrInstantiateCreate2Factory() internal returns (address) {
        // Create2Factory is already deployed on the public networks
        address contractAddress;
        if (isNetworkLocal()) {
            vm.broadcast(deployerPrivateKey);
            SingletonFactory factory = new SingletonFactory();
            contractAddress = address(factory);
            console.log("Create2Factory deployed at:", contractAddress);
        } else {
            contractAddress = vm.envAddress("CONTRACTS_CREATE2_FACTORY_ADDR");
            console.log("Using Create2Factory address:", contractAddress);
        }
        addresses.create2Factory = contractAddress;
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on the public networks
        if (isNetworkLocal()) {
            address contractAddress = deployViaCreate2(type(Multicall3).creationCode);
            console.log("Multicall3 deployed at:", contractAddress);
        }
    }

    function deployVerifier() internal {
        address contractAddress = deployViaCreate2(type(Verifier).creationCode);
        console.log("Verifier deployed at:", contractAddress);
        addresses.stateTransition.verifier = contractAddress;
    }

    function deployDefaultUpgrade() internal {
        address contractAddress = deployViaCreate2(type(DefaultUpgrade).creationCode);
        console.log("DefaultUpgrade deployed at:", contractAddress);
        addresses.stateTransition.defaultUpgrade = contractAddress;
    }

    function deployGenesisUpgrade() internal {
        address contractAddress = deployViaCreate2(type(GenesisUpgrade).creationCode);
        console.log("GenesisUpgrade deployed at:", contractAddress);
        addresses.stateTransition.genesisUpgrade = contractAddress;
    }

    function deployValidatorTimelock() internal {
        uint32 executionDelay = uint32(vm.envUint("CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY"));
        bytes memory bytecode = abi.encodePacked(
            type(ValidatorTimelock).creationCode,
            abi.encode(deployerAddress, executionDelay, chainId)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("ValidatorTimelock deployed at:", contractAddress);
        addresses.validatorTimelock = contractAddress;
    }

    function deployGovernance() internal {
        bytes memory bytecode = abi.encodePacked(
            type(Governance).creationCode,
            abi.encode(deployerAddress, address(0), uint256(0))
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Governance deployed at:", contractAddress);
        addresses.governance = contractAddress;
    }

    function deployTransparentProxyAdmin() internal {
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        proxyAdmin.transferOwnership(addresses.governance);
        addresses.transparentProxyAdmin = address(proxyAdmin);
    }

    function deployBridgehubContract() internal {
        address bridgehubImplementation = deployViaCreate2(type(Bridgehub).creationCode);
        console.log("Bridgehub Implementation deployed at:", bridgehubImplementation);
        addresses.bridgehub.bridgehubImplementation = bridgehubImplementation;

        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                bridgehubImplementation,
                addresses.transparentProxyAdmin,
                abi.encodeCall(Bridgehub.initialize, (deployerAddress))
            )
        );
        address bridgehubProxy = deployViaCreate2(bytecode);
        console.log("Bridgehub Proxy deployed at:", bridgehubProxy);
        addresses.bridgehub.bridgehubProxy = bridgehubProxy;
    }

    function deployBlobVersionedHashRetriever() internal {
        // solc contracts/state-transition/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
        bytes memory bytecode = hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
        address contractAddress = deployViaCreate2(abi.encode(bytecode));
        console.log("BlobVersionedHashRetriever deployed at:", contractAddress);
        addresses.blobVersionedHashRetriever = contractAddress;
    }

    function deployStateTransitionManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployStateTransitionManagerImplementation();
        deployStateTransitionManagerProxy();
        registerStateTransitionManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        address executorFacet = deployViaCreate2(type(ExecutorFacet).creationCode);
        console.log("ExecutorFacet deployed at:", executorFacet);
        addresses.stateTransition.executorFacet = executorFacet;

        address adminFacet = deployViaCreate2(type(AdminFacet).creationCode);
        console.log("AdminFacet deployed at:", adminFacet);
        addresses.stateTransition.adminFacet = adminFacet;

        address mailboxFacet = deployViaCreate2(abi.encodePacked(type(MailboxFacet).creationCode, abi.encode(chainId)));
        console.log("MailboxFacet deployed at:", mailboxFacet);
        addresses.stateTransition.mailboxFacet = mailboxFacet;

        address gettersFacet = deployViaCreate2(type(GettersFacet).creationCode);
        console.log("GettersFacet deployed at:", gettersFacet);
        addresses.stateTransition.gettersFacet = gettersFacet;

        address diamondInit = deployViaCreate2(type(DiamondInit).creationCode);
        console.log("DiamondInit deployed at:", diamondInit);
        addresses.stateTransition.diamondInit = diamondInit;
    }

    function deployStateTransitionManagerImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(StateTransitionManager).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("StateTransitionManagerImplementation deployed at:", contractAddress);
        addresses.stateTransition.stateTransitionImplementation = contractAddress;
    }

    function deployStateTransitionManagerProxy() internal {
        bytes32 genesisBatchHash = vm.envBytes32("CONTRACTS_GENESIS_ROOT");
        uint256 genesisRollupLeafIndex = vm.envUint("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX");
        bytes32 genesisBatchCommitment = vm.envBytes32("CONTRACTS_GENESIS_BATCH_COMMITMENT");
        uint256 protocolVersion = vm.envUint("CONTRACTS_LATEST_PROTOCOL_VERSION");

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: addresses.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: addresses.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: addresses.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: addresses.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getAllSelectors(addresses.stateTransition.executorFacet.code)
        });

        VerifierParams memory verifierParams;
        if (
            keccak256(abi.encodePacked(vm.envOr("CONTRACTS_PROVER_AT_GENESIS", string("")))) ==
            keccak256(abi.encodePacked("fri"))
        ) {
            verifierParams = VerifierParams({
                recursionNodeLevelVkHash: vm.envBytes32("CONTRACTS_FRI_RECURSION_NODE_LEVEL_VK_HASH"),
                recursionLeafLevelVkHash: vm.envBytes32("CONTRACTS_FRI_RECURSION_LEAF_LEVEL_VK_HASH"),
                recursionCircuitsSetVksHash: bytes32(0)
            });
        } else {
            verifierParams = VerifierParams({
                recursionNodeLevelVkHash: vm.envBytes32("CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH"),
                recursionLeafLevelVkHash: vm.envBytes32("CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH"),
                recursionCircuitsSetVksHash: vm.envBytes32("CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH")
            });
        }

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 120_000,
            maxL2GasPerBatch: 80000000,
            priorityTxMaxPubdata: 99000,
            minimalL2GasPrice: 250000000
        });

        DiamondInitInitializeData memory initializeData = DiamondInitInitializeData({
            chainId: 1,
            bridgehub: address(0x1234),
            stateTransitionManager: address(0x2234),
            protocolVersion: 0x2234,
            admin: address(0x3234),
            validatorTimelock: address(0x4234),
            baseToken: address(0x4234),
            baseTokenBridge: address(0x4234),
            storedBatchZero: hex"5432",
            verifier: IVerifier(addresses.stateTransition.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: bytes32(getBatchBootloaderBytecodeHash()),
            l2DefaultAccountBytecodeHash: bytes32(readSystemContractsBytecode("DefaultAccount")),
            priorityTxMaxGasLimit: vm.envUint("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT"),
            feeParams: feeParams,
            blobVersionedHashRetriever: addresses.blobVersionedHashRetriever
        });
        bytes memory initCallData = abi.encodeCall(DiamondInit.initialize, (initializeData));

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: addresses.stateTransition.diamondInit,
            initCalldata: initCallData
        });

        StateTransitionManagerInitializeData memory diamondInitData = StateTransitionManagerInitializeData({
            governor: deployerAddress,
            validatorTimelock: addresses.validatorTimelock,
            genesisUpgrade: addresses.stateTransition.genesisUpgrade,
            genesisBatchHash: genesisBatchHash,
            genesisIndexRepeatedStorageChanges: uint64(genesisRollupLeafIndex),
            genesisBatchCommitment: genesisBatchCommitment,
            diamondCut: diamondCut,
            protocolVersion: protocolVersion
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
        vm.broadcast(deployerPrivateKey);
        bridgehub.addStateTransitionManager(addresses.stateTransition.stateTransitionProxy);
        console.log("StateTransitionManager registered");
    }

    function setStateTransitionManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        vm.broadcast(deployerPrivateKey);
        validatorTimelock.setStateTransitionManager(
            IStateTransitionManager(addresses.stateTransition.stateTransitionProxy)
        );
        console.log("StateTransitionManager set in ValidatorTimelock");
    }

    function deployErc20BridgeProxy() internal {
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridgehub.bridgehubProxy, addresses.transparentProxyAdmin, bytes(hex""))
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Erc20BridgeProxy deployed at:", contractAddress);
        addresses.bridges.erc20BridgeProxy = contractAddress;
    }

    function deploySharedBridgeContracts() internal {
        deploySharedBridgeImplementation();
        deploySharedBridgeProxy();
        registerSharedBridge();
    }

    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1SharedBridge).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                vm.envAddress("TOKEN_WETH_ADDRESS"),
                addresses.bridgehub.bridgehubProxy,
                addresses.bridges.erc20BridgeProxy,
                chainId,
                addresses.bridges.erc20BridgeImplementation,
                addresses.stateTransition.diamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeImplementation deployed at:", contractAddress);
        addresses.bridges.sharedBridgeImplementation = contractAddress;
    }

    function deploySharedBridgeProxy() internal {
        uint256 storageSwitch = vm.envUint("CONTRACTS_SHARED_BRIDGE_UPGRADE_STORAGE_SWITCH");
        bytes memory initCalldata = abi.encodeCall(L1SharedBridge.initialize, (addresses.governance, storageSwitch));
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridges.sharedBridgeImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeProxy deployed at:", contractAddress);
    }

    function registerSharedBridge() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(deployerPrivateKey);
        bridgehub.addToken(address(0x01));
        bridgehub.setSharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function deployErc20BridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1ERC20Bridge).creationCode,
            abi.encode(addresses.bridges.sharedBridgeProxy)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("Erc20BridgeImplementation deployed at:", contractAddress);
        addresses.bridges.erc20BridgeImplementation = contractAddress;
    }

    function upgradeL1Erc20Bridge() internal {
        // In local network, we need to change the block.number
        // as the operation could be scheduled for timestamp 1
        // which is also a magic number meaning the operation
        // is done.
        if (isNetworkLocal()) {
            vm.warp(10);
        }

        bytes memory callData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(addresses.bridges.erc20BridgeProxy),
                addresses.bridges.erc20BridgeImplementation,
                abi.encodeCall(L1ERC20Bridge.initialize, ())
            )
        );

        IGovernance.Call[] memory calls = new IGovernance.Call[](1);
        calls[0] = IGovernance.Call({target: addresses.transparentProxyAdmin, value: 0, data: callData});

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        Governance governance = Governance(payable(addresses.governance));

        vm.startBroadcast(deployerPrivateKey);
        governance.scheduleTransparent(operation, 0);
        governance.execute(operation);
        vm.stopBroadcast();
        console.log("L1Erc20Bridge upgraded");
    }

    function isNetworkLocal() internal view returns (bool) {
        return keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("local"));
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        if (_bytecode.length == 0) {
            revert("Bytecode is not set");
        }

        SingletonFactory create2Factory = SingletonFactory(addresses.create2Factory);
        vm.broadcast(deployerPrivateKey);
        address contractAddress = create2Factory.deploy(_bytecode, create2Salt);

        if (contractAddress == address(0)) {
            revert("Failed to deploy contract via create2");
        }

        return contractAddress;
    }

    function getAllSelectors(bytes memory bytecode) internal returns (bytes4[] memory) {
        string[] memory input = new string[](3);
        input[0] = "cast";
        input[1] = "selectors";
        input[2] = vm.toString(bytecode);
        bytes memory result = vm.ffi(input);
        string memory stringResult = string(abi.encodePacked(result));

        // Extract selectors from the result
        string[] memory parts = vm.split(stringResult, "\n");
        bytes4[] memory selectors = new bytes4[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            bytes memory part = bytes(parts[i]);
            bytes memory extractedSelector = new bytes(10);
            // Selector length 10 is 0x + 4 bytes
            for (uint256 j = 0; j < 10; j++) {
                extractedSelector[j] = part[j];
            }
            bytes4 selector = bytes4(vm.parseBytes(string(extractedSelector)));
            selectors[i] = selector;
        }

        return selectors;
    }

    function getBatchBootloaderBytecodeHash() internal view returns (bytes memory) {
        return vm.readFileBinary("../system-contracts/bootloader/build/artifacts/proved_batch.yul.zbin");
    }

    function readSystemContractsBytecode(string memory filename) internal view returns (bytes memory) {
        string memory file = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat(
                "../system-contracts/artifacts-zk/contracts-preprocessed/",
                filename,
                ".sol/",
                filename,
                ".json"
            )
        );
        bytes memory bytecode = vm.parseJson(file, "$.bytecode");
        return bytecode;
    }
}
