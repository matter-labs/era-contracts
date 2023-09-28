// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {Utils, DEFAULT_L2_LOGS_TREE_ROOT_HASH} from "../Utils/Utils.sol";
import {AllowList} from "../../../../../cache/solpp-generated-contracts/common/AllowList.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER} from "../../../../../cache/solpp-generated-contracts/zksync/Config.sol";
import {DiamondInit} from "../../../../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import {DiamondProxy} from "../../../../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";
import {VerifierParams} from "../../../../../cache/solpp-generated-contracts/zksync/Storage.sol";
import {ExecutorFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Executor.sol";
import {GettersFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import {AdminFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Admin.sol";
import {MailboxFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Mailbox.sol";
import {IExecutor} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IExecutor.sol";
import {Diamond} from "../../../../../cache/solpp-generated-contracts/zksync/libraries/Diamond.sol";

contract ExecutorTest is Test {
    address internal owner;
    address internal validator;
    address internal randomSigner;
    AllowList internal allowList;
    AdminFacet internal admin;
    ExecutorFacet internal executor;
    GettersFacet internal getters;
    MailboxFacet internal mailbox;
    bytes32 internal newCommittedBlockBatchHash;
    bytes32 internal newCommittedBlockCommitment;
    uint256 internal currentTimestamp;
    IExecutor.CommitBatchInfo internal newCommitBatchInfo;
    IExecutor.StoredBatchInfo internal newStoredBatchInfo;

    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    IExecutor.ProofInput internal proofInput;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = admin.setPendingGovernor.selector;
        selectors[1] = admin.acceptGovernor.selector;
        selectors[2] = admin.setPendingAdmin.selector;
        selectors[3] = admin.acceptAdmin.selector;
        selectors[4] = admin.setValidator.selector;
        selectors[5] = admin.setPorterAvailability.selector;
        selectors[6] = admin.setPriorityTxMaxGasLimit.selector;
        selectors[7] = admin.executeUpgrade.selector;
        selectors[8] = admin.freezeDiamond.selector;
        selectors[9] = admin.unfreezeDiamond.selector;
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
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = getters.getVerifier.selector;
        selectors[1] = getters.getGovernor.selector;
        selectors[2] = getters.getPendingGovernor.selector;
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
        selectors[18] = getters.getAllowList.selector;
        selectors[19] = getters.isEthWithdrawalFinalized.selector;
        selectors[20] = getters.facets.selector;
        selectors[21] = getters.facetFunctionSelectors.selector;
        selectors[22] = getters.facetAddresses.selector;
        selectors[23] = getters.facetAddress.selector;
        selectors[24] = getters.isFunctionFreezable.selector;
        selectors[25] = getters.isFacetFreezable.selector;
        selectors[26] = getters.getTotalBatchesCommitted.selector;
        selectors[27] = getters.getTotalBatchesVerified.selector;
        selectors[28] = getters.getTotalBatchesExecuted.selector;
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

    constructor() {
        owner = makeAddr("owner");
        validator = makeAddr("validator");
        randomSigner = makeAddr("randomSigner");

        executor = new ExecutorFacet();
        admin = new AdminFacet();
        getters = new GettersFacet();
        mailbox = new MailboxFacet();

        allowList = new AllowList(owner);
        DiamondInit diamondInit = new DiamondInit();

        bytes8 dummyHash = 0x1234567890123456;
        address dummyAddress = makeAddr("dummyAddress");
        bytes memory diamondInitData = abi.encodeWithSelector(
            diamondInit.initialize.selector,
            dummyAddress, //verifier
            owner,
            owner,
            0,
            0,
            0,
            allowList,
            VerifierParams({recursionNodeLevelVkHash: 0, recursionLeafLevelVkHash: 0, recursionCircuitsSetVksHash: 0}),
            false,
            dummyHash,
            dummyHash,
            1000000
        );

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

        vm.prank(owner);
        allowList.setAccessMode(address(diamondProxy), IAllowList.AccessMode.Public);

        executor = ExecutorFacet(address(diamondProxy));
        getters = GettersFacet(address(diamondProxy));
        mailbox = MailboxFacet(address(diamondProxy));
        admin = AdminFacet(address(diamondProxy));

        vm.prank(owner);
        admin.setValidator(validator, true);

        uint256[] memory recursiveAggregationInput;
        uint256[] memory serializedProof;
        proofInput = IExecutor.ProofInput(recursiveAggregationInput, serializedProof);

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
            totalL2ToL1Pubdata: abi.encodePacked(uint256(0))
        });
    }
}
