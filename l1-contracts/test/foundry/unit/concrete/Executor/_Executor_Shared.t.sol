// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Utils, DEFAULT_L2_LOGS_TREE_ROOT_HASH} from "../Utils/Utils.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER, ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DummyEraBaseTokenBridge} from "contracts/dev-contracts/test/DummyEraBaseTokenBridge.sol";
import {DummyStateTransitionManager} from "contracts/dev-contracts/test/DummyStateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {TestExecutor} from "contracts/dev-contracts/test/TestExecutor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";

contract ExecutorTest is Test {
    address internal owner;
    address internal validator;
    address internal randomSigner;
    address internal blobVersionedHashRetriever;
    AdminFacet internal admin;
    TestExecutor internal executor;
    GettersFacet internal getters;
    MailboxFacet internal mailbox;
    bytes32 internal newCommittedBlockBatchHash;
    bytes32 internal newCommittedBlockCommitment;
    uint256 internal currentTimestamp;
    IExecutor.CommitBatchInfo internal newCommitBatchInfo;
    IExecutor.StoredBatchInfo internal newStoredBatchInfo;

    uint256 eraChainId;

    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    IExecutor.ProofInput internal proofInput;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = admin.setPendingAdmin.selector;
        selectors[1] = admin.acceptAdmin.selector;
        selectors[2] = admin.setValidator.selector;
        selectors[3] = admin.setPorterAvailability.selector;
        selectors[4] = admin.setPriorityTxMaxGasLimit.selector;
        selectors[5] = admin.changeFeeParams.selector;
        selectors[6] = admin.setTokenMultiplier.selector;
        selectors[7] = admin.upgradeChainFromVersion.selector;
        selectors[8] = admin.executeUpgrade.selector;
        selectors[9] = admin.freezeDiamond.selector;
        selectors[10] = admin.unfreezeDiamond.selector;
        return selectors;
    }

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = executor.commitBatches.selector;
        selectors[1] = executor.proveBatches.selector;
        selectors[2] = executor.executeBatches.selector;
        selectors[3] = executor.revertBatches.selector;
        return selectors;
    }

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](28);
        selectors[0] = getters.getVerifier.selector;
        selectors[1] = getters.getAdmin.selector;
        selectors[2] = getters.getPendingAdmin.selector;
        selectors[3] = getters.getTotalBlocksCommitted.selector;
        selectors[4] = getters.getTotalBlocksVerified.selector;
        selectors[5] = getters.getTotalBlocksExecuted.selector;
        selectors[6] = getters.getTotalPriorityTxs.selector;
        selectors[7] = getters.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = getters.getPriorityQueueSize.selector;
        selectors[9] = getters.priorityQueueFrontOperation.selector;
        selectors[10] = getters.isValidator.selector;
        selectors[11] = getters.l2LogsRootHash.selector;
        selectors[12] = getters.storedBatchHash.selector;
        selectors[13] = getters.getL2BootloaderBytecodeHash.selector;
        selectors[14] = getters.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = getters.getVerifierParams.selector;
        selectors[16] = getters.isDiamondStorageFrozen.selector;
        selectors[17] = getters.getPriorityTxMaxGasLimit.selector;
        selectors[18] = getters.isEthWithdrawalFinalized.selector;
        selectors[19] = getters.facets.selector;
        selectors[20] = getters.facetFunctionSelectors.selector;
        selectors[21] = getters.facetAddresses.selector;
        selectors[22] = getters.facetAddress.selector;
        selectors[23] = getters.isFunctionFreezable.selector;
        selectors[24] = getters.isFacetFreezable.selector;
        selectors[25] = getters.getTotalBatchesCommitted.selector;
        selectors[26] = getters.getTotalBatchesVerified.selector;
        selectors[27] = getters.getTotalBatchesExecuted.selector;
        return selectors;
    }

    function getMailboxSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = mailbox.proveL2MessageInclusion.selector;
        selectors[1] = mailbox.proveL2LogInclusion.selector;
        selectors[2] = mailbox.proveL1ToL2TransactionStatus.selector;
        selectors[3] = mailbox.finalizeEthWithdrawal.selector;
        selectors[4] = mailbox.requestL2Transaction.selector;
        selectors[5] = mailbox.l2TransactionBaseCost.selector;
        return selectors;
    }

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

    constructor() {
        owner = makeAddr("owner");
        validator = makeAddr("validator");
        randomSigner = makeAddr("randomSigner");
        blobVersionedHashRetriever = makeAddr("blobVersionedHashRetriever");

        eraChainId = 9;

        executor = new TestExecutor();
        admin = new AdminFacet();
        getters = new GettersFacet();
        mailbox = new MailboxFacet(eraChainId);

        DummyStateTransitionManager stateTransitionManager = new DummyStateTransitionManager();
        vm.mockCall(
            address(stateTransitionManager),
            abi.encodeWithSelector(IStateTransitionManager.protocolVersionIsActive.selector),
            abi.encode(bool(true))
        );
        DiamondInit diamondInit = new DiamondInit();

        bytes8 dummyHash = 0x1234567890123456;

        genesisStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: bytes32(""),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: bytes32("")
        });

        TestnetVerifier testnetVerifier = new TestnetVerifier();

        InitializeData memory params = InitializeData({
            // TODO REVIEW
            chainId: eraChainId,
            bridgehub: makeAddr("bridgehub"),
            stateTransitionManager: address(stateTransitionManager),
            protocolVersion: 0,
            admin: owner,
            validatorTimelock: validator,
            baseToken: ETH_TOKEN_ADDRESS,
            baseTokenBridge: address(new DummyEraBaseTokenBridge()),
            storedBatchZero: keccak256(abi.encode(genesisStoredBatchInfo)),
            verifier: IVerifier(testnetVerifier), // verifier
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: 0,
                recursionLeafLevelVkHash: 0,
                recursionCircuitsSetVksHash: 0
            }),
            l2BootloaderBytecodeHash: dummyHash,
            l2DefaultAccountBytecodeHash: dummyHash,
            priorityTxMaxGasLimit: 1000000,
            feeParams: defaultFeeParams(),
            blobVersionedHashRetriever: blobVersionedHashRetriever
        });

        bytes memory diamondInitData = abi.encodeWithSelector(diamondInit.initialize.selector, params);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(admin),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(executor),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getExecutorSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(getters),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getGettersSelectors()
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: address(mailbox),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitData
        });

        uint256 chainId = block.chainid;
        DiamondProxy diamondProxy = new DiamondProxy(chainId, diamondCutData);

        executor = TestExecutor(address(diamondProxy));
        getters = GettersFacet(address(diamondProxy));
        mailbox = MailboxFacet(address(diamondProxy));
        admin = AdminFacet(address(diamondProxy));

        // Initiate the token multiplier to enable L1 -> L2 transactions.
        vm.prank(address(stateTransitionManager));
        admin.setTokenMultiplier(1, 1);

        uint256[] memory recursiveAggregationInput;
        uint256[] memory serializedProof;
        proofInput = IExecutor.ProofInput(recursiveAggregationInput, serializedProof);

        // foundry's default value is 1 for the block's timestamp, it is expected
        // that block.timestamp > COMMIT_TIMESTAMP_NOT_OLDER + 1
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1 + 1);
        currentTimestamp = block.timestamp;

        bytes memory l2Logs = Utils.encodePacked(Utils.createSystemLogs());
        newCommitBatchInfo = IExecutor.CommitBatchInfo({
            batchNumber: 1,
            timestamp: uint64(currentTimestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            bootloaderHeapInitialContentsHash: Utils.randomBytes32("bootloaderHeapInitialContentsHash"),
            eventsQueueStateHash: Utils.randomBytes32("eventsQueueStateHash"),
            systemLogs: l2Logs,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
