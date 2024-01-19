// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../../Utils/Utils.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Bridgehub} from "solpp/bridgehub/BridgeHub.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "solpp/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "solpp/state-transition/chain-deps/DiamondProxy.sol";
import {GettersFacet} from "solpp/state-transition/chain-deps/facets/Getters.sol";
import {IBridgehub} from "solpp/bridgehub/IBridgehub.sol";
import {InitializeData} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {IVerifier} from "solpp/state-transition/chain-interfaces/IVerifier.sol";
import {IZkSyncStateTransition} from "solpp/state-transition/chain-interfaces/IZkSyncStateTransition.sol";
import {L1WethBridge} from "solpp/bridge/L1WethBridge.sol";
import {MailboxFacet} from "solpp/state-transition/chain-deps/facets/Mailbox.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "solpp/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {WETH9} from "solpp/dev-contracts/WETH9.sol";

contract L1WethBridgeTest is Test {
    address internal owner;
    address internal randomSigner;
    L1WethBridge internal bridgeProxy;
    WETH9 internal l1Weth;
    bytes4 internal functionSignature = 0x6c0960f9;

    function defaultFeeParams() private pure returns (FeeParams memory feeParams) {
        feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 110_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 250_000_000
        });
    }

    function setUp() public {
        owner = makeAddr("owner");
        randomSigner = makeAddr("randomSigner");

        GettersFacet gettersFacet = new GettersFacet();
        MailboxFacet mailboxFacet = new MailboxFacet();
        DiamondInit diamondInit = new DiamondInit();

        bytes8 dummyHash = 0x1234567890123456;
        address dummyAddress = makeAddr("dummyAddress");

        InitializeData memory params = InitializeData({
            // TODO REVIEW
            chainId: 1,
            bridgehub: makeAddr("bridgehub"),
            stateTransitionManager: makeAddr("stateTransitionManager"),
            protocolVersion: 0,
            governor: owner,
            admin: owner,
            baseToken: makeAddr("baseToken"),
            baseTokenBridge: makeAddr("baseTokenBridge"),
            storedBatchZero: bytes32(0),
            // genesisBatchHash: bytes32(0),
            // genesisIndexRepeatedStorageChanges: 0,
            // genesisBatchCommitment: bytes32(0),
            verifier: IVerifier(dummyAddress),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: 0,
                recursionLeafLevelVkHash: 0,
                recursionCircuitsSetVksHash: 0
            }),
            // zkPorterIsAvailable: false,
            l2BootloaderBytecodeHash: dummyHash,
            l2DefaultAccountBytecodeHash: dummyHash,
            priorityTxMaxGasLimit: 10000000,
            // initialProtocolVersion: 0,
            feeParams: defaultFeeParams()
        });

        bytes memory diamondInitData = abi.encodeWithSelector(diamondInit.initialize.selector, params);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getGettersSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitData
        });

        uint256 chainId = block.chainid;
        DiamondProxy diamondProxy = new DiamondProxy(chainId, diamondCutData);

        l1Weth = new WETH9();

        // address[] addresses = Utils.initial_deployment();

        IBridgehub bridgehub = new Bridgehub();
        L1WethBridge bridge = new L1WethBridge(payable(address(l1Weth)), bridgehub);

        bytes memory garbageBytecode = abi.encodePacked(
            bytes32(0x1111111111111111111111111111111111111111111111111111111111111111)
        );
        address garbageAddress = makeAddr("garbageAddress");

        bytes[] memory factoryDeps = new bytes[](2);
        factoryDeps[0] = garbageBytecode;
        factoryDeps[1] = garbageBytecode;
        bytes memory bridgeInitData = abi.encodeWithSelector(
            bridge.initialize.selector,
            factoryDeps,
            garbageAddress,
            owner,
            1000000000000000000,
            1000000000000000000
        );

        ERC1967Proxy x = new ERC1967Proxy{value: 2000000000000000000}(address(bridge), bridgeInitData);

        bridgeProxy = L1WethBridge(payable(address(x)));
    }
}
