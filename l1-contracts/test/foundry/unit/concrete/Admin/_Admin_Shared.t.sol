// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {DiamondProxy} from "solpp/zksync/DiamondProxy.sol";
import {DiamondInit} from "solpp/zksync/DiamondInit.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "solpp/zksync/Storage.sol";
import {Diamond} from "solpp/zksync/libraries/Diamond.sol";
import {AdminFacet} from "solpp/zksync/facets/Admin.sol";
import {Base} from "solpp/zksync/facets/Base.sol";
import {Governance} from "solpp/governance/Governance.sol";
import {IVerifier} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IVerifier.sol";

contract GettersMock is Base {
    function getFeeParams() public returns (FeeParams memory) {
        return s.feeParams;
    }
}

contract AdminTest is Test {
    DiamondProxy internal diamondProxy;
    address internal owner;
    address internal securityCouncil;
    address internal governor;
    AdminFacet internal adminFacet;
    AdminFacet internal proxyAsAdmin;
    GettersMock internal proxyAsGettersMock;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory dcSelectors = new bytes4[](11);
        dcSelectors[0] = adminFacet.setPendingGovernor.selector;
        dcSelectors[1] = adminFacet.acceptGovernor.selector;
        dcSelectors[2] = adminFacet.setPendingAdmin.selector;
        dcSelectors[3] = adminFacet.acceptAdmin.selector;
        dcSelectors[4] = adminFacet.setValidator.selector;
        dcSelectors[5] = adminFacet.setPorterAvailability.selector;
        dcSelectors[6] = adminFacet.setPriorityTxMaxGasLimit.selector;
        dcSelectors[7] = adminFacet.executeUpgrade.selector;
        dcSelectors[8] = adminFacet.freezeDiamond.selector;
        dcSelectors[9] = adminFacet.unfreezeDiamond.selector;
        dcSelectors[10] = adminFacet.changeFeeParams.selector;
        return dcSelectors;
    }

    function getGettersMockSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory dcSelectors = new bytes4[](1);
        dcSelectors[0] = proxyAsGettersMock.getFeeParams.selector;
        return dcSelectors;
    }

    function setUp() public {
        owner = makeAddr("owner");
        securityCouncil = makeAddr("securityCouncil");
        governor = makeAddr("governor");
        DiamondInit diamondInit = new DiamondInit();

        VerifierParams memory dummyVerifierParams = VerifierParams({
            recursionNodeLevelVkHash: 0,
            recursionLeafLevelVkHash: 0,
            recursionCircuitsSetVksHash: 0
        });

        DiamondInit.InitializeData memory params = DiamondInit.InitializeData({
            verifier: IVerifier(0x03752D8252d67f99888E741E3fB642803B29B155), // verifier
            governor: governor,
            admin: owner,
            genesisBatchHash: 0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21,
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(0),
            verifierParams: dummyVerifierParams,
            zkPorterIsAvailable: false,
            l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            priorityTxMaxGasLimit: 500000, // priority tx max L2 gas limit
            initialProtocolVersion: 0,
            feeParams: FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            })
        });

        adminFacet = new AdminFacet();
        GettersMock gettersMock = new GettersMock();

        bytes memory diamondInitCalldata = abi.encodeWithSelector(diamondInit.initialize.selector, params);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(adminFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(gettersMock),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getGettersMockSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitCalldata
        });

        diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        proxyAsAdmin = AdminFacet(address(diamondProxy));
        proxyAsGettersMock = GettersMock(address(diamondProxy));
    }
}
