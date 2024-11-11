// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DummyStateTransitionManagerWBH} from "contracts/dev-contracts/test/DummyStateTransitionManagerWithBridgeHubAddress.sol";
import "contracts/bridgehub/Bridgehub.sol";
import "contracts/chain-registrator/ChainRegistrar.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import "contracts/dev-contracts/test/DummyBridgehub.sol";
import "contracts/dev-contracts/test/DummySharedBridge.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {console2 as console} from "forge-std/Script.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";

contract ChainRegistrarTest is Test {
    DummyBridgehub private bridgeHub;
    DummyStateTransitionManagerWBH private stm;
    address private admin;
    address private deployer;
    ChainRegistrar private chainRegistrar;
    L1SharedBridge private sharedBridge;
    bytes diamondCutData;

    constructor () public {
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

        Diamond.DiamondCutData memory diamondCutDataStruct = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: makeAddr("init"),
            initCalldata: bytes("")
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
        chainRegistrar = new ChainRegistrar(address(bridgeHub), deployer);
        chainRegistrar.initialize(admin);
    }

    function test_SuccessfulProposal() public {
        address author = makeAddr("author");
        ChainRegistrar.BaseToken memory baseToken = ChainRegistrar.BaseToken({
            tokenAddress: ETH_TOKEN_ADDRESS,
            tokenMultiplierSetter: makeAddr("setter"),
            gasPriceMultiplierNominator: 1,
            gasPriceMultiplierDenominator: 1
        });
        vm.prank(author);
        vm.recordLogs();
        chainRegistrar.proposeChainRegistration(ChainRegistrar.ChainConfig({
            chainId: 1,
            pubdataPricingMode: PubdataPricingMode.Validium,
            baseToken: baseToken,
            commitOperator: makeAddr("commitOperator"),
            operator: makeAddr("operator"),
            governor: makeAddr("governor")
        }));
        Vm.Log[] memory proposeLogs = vm.getRecordedLogs();
        console.logAddress(admin);
        console.logAddress(bridgeHub.admin());
        console.logAddress(bridgeHub.owner());
        vm.prank(admin);

        bridgeHub.createNewChain(1, address(stm), baseToken.tokenAddress, 0, admin, diamondCutData);
        vm.prank(admin);
//        sharedBridge.initializeChainGovernance(1, makeAddr("l2bridge"));
        vm.recordLogs();
//        chainRegistrar.chainRegistered(author, 1);
        Vm.Log[] memory registeredLogs = vm.getRecordedLogs();

    }
}
