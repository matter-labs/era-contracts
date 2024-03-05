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
    address internal constant newChainAdmin = address(0x6060606);
    uint256 chainId = block.chainid;

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");

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
                selectors: getAdminSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new ExecutorFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: getExecutorSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new GettersFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: getGettersSelectors()
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

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AdminFacet.setPendingAdmin.selector;
        selectors[1] = AdminFacet.acceptAdmin.selector;
        selectors[2] = AdminFacet.setValidator.selector;
        selectors[3] = AdminFacet.setPorterAvailability.selector;
        selectors[4] = AdminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[5] = AdminFacet.changeFeeParams.selector;
        selectors[6] = AdminFacet.setTokenMultiplier.selector;
        selectors[7] = AdminFacet.upgradeChainFromVersion.selector;
        selectors[8] = AdminFacet.executeUpgrade.selector;
        selectors[9] = AdminFacet.freezeDiamond.selector;
        selectors[10] = AdminFacet.unfreezeDiamond.selector;
        return selectors;
    }

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ExecutorFacet.commitBatches.selector;
        selectors[1] = ExecutorFacet.proveBatches.selector;
        selectors[2] = ExecutorFacet.executeBatches.selector;
        selectors[3] = ExecutorFacet.revertBatches.selector;
        return selectors;
    }

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = GettersFacet.getVerifier.selector;
        selectors[1] = GettersFacet.getAdmin.selector;
        selectors[2] = GettersFacet.getPendingAdmin.selector;
        selectors[3] = GettersFacet.getTotalBlocksCommitted.selector;
        selectors[4] = GettersFacet.getTotalBlocksVerified.selector;
        selectors[5] = GettersFacet.getTotalBlocksExecuted.selector;
        selectors[6] = GettersFacet.getTotalPriorityTxs.selector;
        selectors[7] = GettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = GettersFacet.getPriorityQueueSize.selector;
        selectors[9] = GettersFacet.priorityQueueFrontOperation.selector;
        selectors[10] = GettersFacet.isValidator.selector;
        selectors[11] = GettersFacet.l2LogsRootHash.selector;
        selectors[12] = GettersFacet.storedBatchHash.selector;
        selectors[13] = GettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[14] = GettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = GettersFacet.getVerifierParams.selector;
        selectors[16] = GettersFacet.isDiamondStorageFrozen.selector;
        selectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[19] = GettersFacet.facets.selector;
        selectors[20] = GettersFacet.facetFunctionSelectors.selector;
        selectors[21] = GettersFacet.facetAddresses.selector;
        selectors[22] = GettersFacet.facetAddress.selector;
        selectors[23] = GettersFacet.isFunctionFreezable.selector;
        selectors[24] = GettersFacet.isFacetFreezable.selector;
        selectors[25] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[26] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[27] = GettersFacet.getTotalBatchesExecuted.selector;
        selectors[28] = GettersFacet.getL2SystemContractsUpgradeTxHash.selector;
        return selectors;
    }

    function getDiamondCutData(address _diamondInit) internal view returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain();

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
