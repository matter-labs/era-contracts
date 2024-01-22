// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {L1WethBridge} from "../../../../../../cache/solpp-generated-contracts/bridge/L1WethBridge.sol";
import {WETH9} from "../../../../../../cache/solpp-generated-contracts/dev-contracts/WETH9.sol";
import {GettersFacet} from "../../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import {MailboxFacet} from "../../../../../../cache/solpp-generated-contracts/zksync/facets/Mailbox.sol";
import {DiamondInit} from "../../../../../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "../../../../../../cache/solpp-generated-contracts/zksync/Storage.sol";
import {Diamond} from "../../../../../../cache/solpp-generated-contracts/zksync/libraries/Diamond.sol";
import {DiamondProxy} from "../../../../../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";
import {Utils} from "../../Utils/Utils.sol";
import {IZkSync} from "../../../../../../cache/solpp-generated-contracts/zksync/interfaces/IZkSync.sol";
import {DiamondInit} from "../../../../../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import {IVerifier} from "../../../../../../cache/solpp-generated-contracts/zksync/interfaces/IVerifier.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

        DiamondInit.InitializeData memory params = DiamondInit.InitializeData({
            verifier: IVerifier(dummyAddress), // verifier
            governor: owner,
            admin: owner,
            genesisBatchHash: bytes32(0),
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(0),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: 0,
                recursionLeafLevelVkHash: 0,
                recursionCircuitsSetVksHash: 0
            }),
            zkPorterIsAvailable: false,
            l2BootloaderBytecodeHash: dummyHash,
            l2DefaultAccountBytecodeHash: dummyHash,
            priorityTxMaxGasLimit: 10000000,
            initialProtocolVersion: 0,
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

        IZkSync zkSync = IZkSync(address(diamondProxy));

        L1WethBridge bridge = new L1WethBridge(payable(address(l1Weth)), zkSync);

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
