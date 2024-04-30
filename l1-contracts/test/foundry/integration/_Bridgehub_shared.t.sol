// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {StateTransitionManagerInitializeData} from "contracts/state-transition/IStateTransitionManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract StateTransitionManagerFactory is Test {
    function getStateTransitionManagerAddress(address bridgeHubAddress) public returns (StateTransitionManager) {
        return new StateTransitionManager(bridgeHubAddress, type(uint256).max);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract BridgeHubIntegration is Test {
    address diamondAddress;
    address stmAddress;
    address bridgeHubOwner;
    address admin;
    address validator;
    address bridgeHubAddress;
    address eraDiamondProxy;
    address l1WethAddress;

    Diamond.FacetCut[] facetCuts;
    TestnetVerifier testnetVerifier;

    uint256 chainId;
    uint256 eraChainId;
    uint256 lastChainId;

    L1SharedBridge l1sharedBridge;
    Bridgehub internal bridgeHub;
    // currently single base token
    TestnetERC20Token token;

    // returns bridgehub address to be used by state transition manager constructor
    function getBridgehubAddress() public returns (address) {
        return address(bridgeHub);
    }

    function registerStateTransitionManager(address _stmAddress) internal {
        vm.prank(bridgeHubOwner);
        bridgeHub.addStateTransitionManager(_stmAddress);
    }

    function registerNewToken(address tokenAddress) internal {
        vm.prank(bridgeHubOwner);
        bridgeHub.addToken(tokenAddress);
    }

    function registerNewChain() internal {
        Diamond.DiamondCutData memory diamondCutData = getDiamondCutData(diamondAddress);

        vm.prank(bridgeHubOwner);
        lastChainId = bridgeHub.createNewChain(
            lastChainId,
            stmAddress,
            address(token),
            uint256(12),
            admin,
            abi.encode(diamondCutData)
        );
    }

    function getDiamondCutData(address _diamondInit) internal returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(address(testnetVerifier));

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function initializeSTM() internal {
        StateTransitionManager stm = new StateTransitionManager(bridgeHubAddress, type(uint256).max);
        GenesisUpgrade genesisUpgradeContract = new GenesisUpgrade();
        DiamondInit diamondInit = new DiamondInit();
        diamondAddress = address(diamondInit);

        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            owner: admin,
            validatorTimelock: validator,
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(""),
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(""),
            diamondCut: getDiamondCutData(diamondAddress),
            protocolVersion: 0
        });

        vm.prank(bridgeHubAddress);
        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(stm),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeData)
        );

        stmAddress = address(transparentUpgradeableProxy);
    }

    constructor() {
        bridgeHubOwner = makeAddr("bridgeHubOwner");
        eraDiamondProxy = makeAddr("eraDiamondProxy");
        admin = makeAddr("admin");
        l1WethAddress = makeAddr("weth");
        validator = makeAddr("validator");
        testnetVerifier = new TestnetVerifier();
        chainId = 1;
        eraChainId = 9;
        lastChainId = 9;

        bridgeHub = new Bridgehub();
        bridgeHubAddress = address(bridgeHub);

        address defaultOwner = bridgeHub.owner();

        vm.prank(defaultOwner);
        bridgeHub.transferOwnership(bridgeHubOwner);

        vm.prank(bridgeHubOwner);
        bridgeHub.acceptOwnership();

        vm.prank(bridgeHubOwner);
        bridgeHub.setPendingAdmin(admin);

        vm.prank(admin);
        bridgeHub.acceptAdmin();

        StateTransitionManager stm = new StateTransitionManager(bridgeHubAddress, type(uint256).max);
        stmAddress = address(stm);

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

        initializeSTM();
        registerStateTransitionManager(stmAddress);

        token = new TestnetERC20Token("ERC20Base", "UWU", 18);
        registerNewToken(address(token));

        l1sharedBridge = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(address(bridgeHub)),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });

        vm.prank(bridgeHubOwner);
        bridgeHub.setSharedBridge(address(l1sharedBridge));
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract IntegrationTests is BridgeHubIntegration {
    function test_depositToBridgeHub() public {
        registerNewChain();

        assert(bridgeHub.getHyperchain(lastChainId) != address(0));
    }
}
