// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "solpp/state-transition/chain-deps/DiamondInit.sol";
import {IDiamondInit} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {InitializeData} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {IVerifier} from "solpp/state-transition/chain-interfaces/IVerifier.sol";
import {StateTransitionManager} from "solpp/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData} from "solpp/state-transition/IStateTransitionManager.sol";

contract StateTransitionManagerTest is Test {
    StateTransitionManager internal stateTransitionManager;
    StateTransitionManager internal chainContractAddress;
    address internal bridgehub;
    address internal diamondInit; 
    address internal constant GOVERNOR = address(0x101010101010101010101);
    address internal constant ADMIN = address(0x202020202020202020202);
    address internal initialValidatorTimelock = address(0x0000000000000000000000000000000000004234);
    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");

        vm.startPrank(bridgehub);
        stateTransitionManager = new StateTransitionManager(bridgehub);
        diamondInit = address(new DiamondInit());

        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );

        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            governor: GOVERNOR,
            validatorTimelock: initialValidatorTimelock,
            genesisUpgrade:  address(0x0000000000000000000000000000000000002234), 
            genesisBatchHash: keccak256(abi.encode(1)),
            genesisIndexRepeatedStorageChanges: uint64(1234),
            genesisBatchCommitment: keccak256(abi.encode(2)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            protocolVersion: uint256(1)
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            ADMIN,
            "" // add here initialize
        );
        chainContractAddress = StateTransitionManager(address(transparentUpgradeableProxy));
        vm.stopPrank();
        vm.startPrank(GOVERNOR);

        chainContractAddress.initialize(stmInitializeData);
    }

    function getDiamondCutData(address diamondInit) internal returns (Diamond.DiamondCutData memory) {    
        InitializeData memory initializeData = Utils.makeInitializeData();
        initializeData.verifier = IVerifier(address(0));

        bytes memory initCalldata = abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData);

        return
            Diamond.DiamondCutData({
                facetCuts: facetCuts,
                initAddress: diamondInit,
                initCalldata: initCalldata
            });
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
