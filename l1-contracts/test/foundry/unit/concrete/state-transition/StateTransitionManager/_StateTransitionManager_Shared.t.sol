// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "solpp/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "solpp/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "solpp/state-transition/chain-deps/facets/Getters.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "solpp/state-transition/chain-deps/DiamondInit.sol";
import {GenesisUpgrade} from "solpp/upgrades/GenesisUpgrade.sol";
import {IDiamondInit} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {InitializeData, InitializeDataNewChain} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {IVerifier} from "solpp/state-transition/chain-interfaces/IVerifier.sol";
import {StateTransitionManager} from "solpp/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData} from "solpp/state-transition/IStateTransitionManager.sol";

contract StateTransitionManagerTest is Test {
    StateTransitionManager internal stateTransitionManager;
    StateTransitionManager internal chainContractAddress;
    GenesisUpgrade internal genesisUpgradeContract;
    address internal bridgehub;
    address internal diamondInit;
    address internal constant governor = address(0x1010101);
    address internal constant admin = address(0x2020202);
    address internal constant baseToken = address(0x3030303);
    address internal constant sharedBridge = address(0x4040404);
    address internal constant validator = address(0x5050505);
    address internal newChainAdmin;
    uint256 chainId = block.chainid;

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(bridgehub);
        stateTransitionManager = new StateTransitionManager(bridgehub);
        diamondInit = address(new DiamondInit());
        genesisUpgradeContract = new GenesisUpgrade();

        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new AdminFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getAdminSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new ExecutorFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getExecutorSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new GettersFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getGettersSelectors()
            })
        );

        StateTransitionManagerInitializeData memory stmInitializeDataNoGovernor = StateTransitionManagerInitializeData({
            governor: address(0),
            validatorTimelock: validator,
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(""),
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(""),
            diamondCut: getDiamondCutData(address(diamondInit)),
            protocolVersion: 0
        });

        vm.expectRevert(bytes.concat("StateTransition: governor zero"));
        TransparentUpgradeableProxy transparentUpgradeableProxyReverting = new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeDataNoGovernor)
        );

        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            governor: governor,
            validatorTimelock: validator,
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(""),
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(""),
            diamondCut: getDiamondCutData(address(diamondInit)),
            protocolVersion: 0
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeData)
        );
        chainContractAddress = StateTransitionManager(address(transparentUpgradeableProxy));

        vm.stopPrank();
        vm.startPrank(governor);
    }

    function getDiamondCutData(address _diamondInit) internal view returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain();

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function createNewChain(Diamond.DiamondCutData memory _diamondCut) internal {
        vm.stopPrank();
        vm.startPrank(bridgehub);

        chainContractAddress.createNewChain(chainId, baseToken, sharedBridge, newChainAdmin, abi.encode(_diamondCut));
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
