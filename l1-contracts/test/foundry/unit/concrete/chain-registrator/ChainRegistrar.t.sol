// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DummyStateTransitionManagerWBH} from "contracts/dev-contracts/test/DummyStateTransitionManagerWithBridgeHubAddress.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import "contracts/bridgehub/Bridgehub.sol";
import "contracts/chain-registrar/ChainRegistrar.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import "contracts/dev-contracts/test/DummyBridgehub.sol";
import "contracts/dev-contracts/test/DummySharedBridge.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {console2 as console} from "forge-std/Script.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {FeeParams} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import "contracts/dev-contracts/test/DummyHyperchain.sol";

contract ChainRegistrarTest is Test {
    DummyBridgehub private bridgeHub;
    DummyStateTransitionManagerWBH private stm;
    address private admin;
    address private deployer;
    ChainRegistrar private chainRegistrar;
    L1SharedBridge private sharedBridge;
    bytes diamondCutData;
    bytes initCalldata;

    constructor() public {
        bridgeHub = new DummyBridgehub();
        stm = new DummyStateTransitionManagerWBH(address(bridgeHub));
        admin = makeAddr("admin");
        deployer = makeAddr("deployer");
        address defaultOwner = bridgeHub.owner();
        vm.prank(defaultOwner);
        bridgeHub.transferOwnership(admin);
        vm.prank(admin);
        bridgeHub.acceptOwnership();

        sharedBridge = new L1SharedBridge({
            _l1WethAddress: makeAddr("weth"),
            _bridgehub: IBridgehub(bridgeHub),
            _eraChainId: 270,
            _eraDiamondProxy: makeAddr("era")
        });
        address defaultOwnerSb = sharedBridge.owner();
        vm.prank(defaultOwnerSb);
        sharedBridge.transferOwnership(admin);
        vm.startPrank(admin);
        sharedBridge.acceptOwnership();
        bridgeHub.setSharedBridge(address(sharedBridge));
        bridgeHub.addStateTransitionManager(address(stm));
        bridgeHub.addToken(ETH_TOKEN_ADDRESS);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(makeAddr("verifier")),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l2BootloaderBytecodeHash: bytes32(0),
            l2DefaultAccountBytecodeHash: bytes32(0),
            priorityTxMaxGasLimit: 10,
            feeParams: FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            }),
            blobVersionedHashRetriever: makeAddr("blob")
        });
        initCalldata = abi.encode(initializeData);

        Diamond.DiamondCutData memory diamondCutDataStruct = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: makeAddr("init"),
            initCalldata: initCalldata
        });
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: makeAddr("genesis"),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: diamondCutDataStruct
        });
        diamondCutData = abi.encode(diamondCutDataStruct);
        vm.stopPrank();
        vm.prank(stm.admin());
        stm.setChainCreationParams(chainCreationParams);
        chainRegistrar = new ChainRegistrar();
        chainRegistrar.initialize(address(bridgeHub), deployer, admin);
    }

    function test_SuccessfulProposal() public {
        address author = makeAddr("author");
        vm.prank(author);
        vm.recordLogs();
        chainRegistrar.proposeChainRegistration({
            chainId: 1,
            pubdataPricingMode: PubdataPricingMode.Validium,
            blobOperator: makeAddr("blobOperator"),
            operator: makeAddr("operator"),
            governor: makeAddr("governor"),
            tokenAddress: ETH_TOKEN_ADDRESS,
            tokenMultiplierSetter: makeAddr("setter"),
            gasPriceMultiplierNominator: 1,
            gasPriceMultiplierDenominator: 1
        });
        Vm.Log[] memory proposeLogs = vm.getRecordedLogs();
        DummyHyperchain hyperchain = new DummyHyperchain(address(bridgeHub), 270);
        hyperchain.initialize(admin);
        vm.prank(admin);
        stm.setHyperchain(1, address(hyperchain));
        bridgeHub.setStateTransitionManager(1, address(stm));
        vm.prank(admin);
        sharedBridge.initializeChainGovernance(1, makeAddr("l2bridge"));
        vm.recordLogs();
        vm.prank(admin);
        chainRegistrar.setChainAsRegistered(author, 1);
        Vm.Log[] memory registeredLogs = vm.getRecordedLogs();
        ChainRegistrar.RegisteredChainConfig memory registeredConfig = chainRegistrar.getRegisteredChainConfig(1);
        require(registeredConfig.diamondProxy != address(0));
        require(registeredConfig.chainAdmin != address(0));
        require(registeredConfig.l2BridgeAddress != address(0));
        require(registeredConfig.pendingChainAdmin != address(0));
    }
}
