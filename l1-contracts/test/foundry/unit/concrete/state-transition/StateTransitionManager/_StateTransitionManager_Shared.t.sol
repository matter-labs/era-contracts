// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";

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
    address internal testnetVerifier = address(new TestnetVerifier());

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(bridgehub);
        stateTransitionManager = new StateTransitionManager(bridgehub, type(uint256).max);
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

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        StateTransitionManagerInitializeData memory stmInitializeDataNoGovernor = StateTransitionManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        vm.expectRevert(bytes.concat("STM: owner zero"));
        new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeDataNoGovernor)
        );

        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
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

    function getDiamondCutData(address _diamondInit) internal returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(testnetVerifier);

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function createNewChain(Diamond.DiamondCutData memory _diamondCut) internal {
        vm.stopPrank();
        vm.startPrank(bridgehub);

        chainContractAddress.createNewChain({
            _chainId: chainId,
            _baseToken: baseToken,
            _sharedBridge: sharedBridge,
            _admin: newChainAdmin,
            _diamondCut: abi.encode(_diamondCut)
        });
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
