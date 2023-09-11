// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../Utils/Utils.sol";
import "../../../../../cache/solpp-generated-contracts/common/AllowList.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/facets/Executor.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/facets/Governance.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/facets/Mailbox.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";

contract ExecutorTest is Test {
    using Utils for *;

    address constant L2_SYSTEM_CONTEXT_ADDRESS =
        0x000000000000000000000000000000000000800B;
    address constant L2_KNOWN_CODE_STORAGE_ADDRESS =
        0x0000000000000000000000000000000000008004;
    address constant L2_TO_L1_MESSENGER =
        0x0000000000000000000000000000000000008008;

    address owner;
    address validator;
    address randomSigner;
    AllowList allowList;
    GovernanceFacet governance;
    ExecutorFacet executor;
    GettersFacet getters;
    MailboxFacet mailbox;
    bytes32 newCommittedBlockBlockHash;
    bytes32 newCommittedBlockCommitment;
    uint256 currentTimestamp;
    IExecutor.CommitBlockInfo newCommitBlockInfo;
    IExecutor.StoredBlockInfo newStoredBlockInfo;

    IExecutor.StoredBlockInfo genesisStoredBlockInfo;
    IExecutor.ProofInput proofInput;

    function getGovernanceSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = governance.setPendingGovernor.selector;
        selectors[1] = governance.acceptGovernor.selector;
        selectors[2] = governance.setValidator.selector;
        selectors[3] = governance.setPorterAvailability.selector;
        selectors[4] = governance.setPriorityTxMaxGasLimit.selector;
        return selectors;
    }

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = executor.commitBlocks.selector;
        selectors[1] = executor.proveBlocks.selector;
        selectors[2] = executor.executeBlocks.selector;
        selectors[3] = executor.revertBlocks.selector;
        return selectors;
    }

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](32);
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
        selectors[12] = getters.storedBlockHash.selector;
        selectors[13] = getters.getL2BootloaderBytecodeHash.selector;
        selectors[14] = getters.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = getters.getVerifierParams.selector;
        selectors[16] = getters.isDiamondStorageFrozen.selector;
        selectors[17] = getters.getSecurityCouncil.selector;
        selectors[18] = getters.getUpgradeProposalState.selector;
        selectors[19] = getters.getProposedUpgradeHash.selector;
        selectors[20] = getters.getProposedUpgradeTimestamp.selector;
        selectors[21] = getters.getCurrentProposalId.selector;
        selectors[22] = getters.isApprovedBySecurityCouncil.selector;
        selectors[23] = getters.getPriorityTxMaxGasLimit.selector;
        selectors[24] = getters.getAllowList.selector;
        selectors[25] = getters.isEthWithdrawalFinalized.selector;
        selectors[26] = getters.facets.selector;
        selectors[27] = getters.facetFunctionSelectors.selector;
        selectors[28] = getters.facetAddresses.selector;
        selectors[29] = getters.facetAddress.selector;
        selectors[30] = getters.isFunctionFreezable.selector;
        selectors[31] = getters.isFacetFreezable.selector;
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
        governance = new GovernanceFacet();
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
            0,
            0,
            0,
            allowList,
            VerifierParams({
                recursionNodeLevelVkHash: 0,
                recursionLeafLevelVkHash: 0,
                recursionCircuitsSetVksHash: 0
            }),
            false,
            dummyHash,
            dummyHash,
            100000000000
        );

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(governance),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getGovernanceSelectors()
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
        allowList.setAccessMode(
            address(diamondProxy),
            IAllowList.AccessMode.Public
        );

        executor = ExecutorFacet(address(diamondProxy));
        getters = GettersFacet(address(diamondProxy));
        mailbox = MailboxFacet(address(diamondProxy));
        governance = GovernanceFacet(address(diamondProxy));

        vm.prank(owner);
        governance.setValidator(validator, true);

        uint256[] memory recursiveAggregationInput;
        uint256[] memory serializedProof;
        proofInput = IExecutor.ProofInput(
            recursiveAggregationInput,
            serializedProof
        );

        genesisStoredBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 0,
            blockHash: 0,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            timestamp: 0,
            commitment: 0
        });

        // foundry's default value is 1 for the block's timestamp, it is expected
        // that block.timestamp > COMMIT_TIMESTAMP_NOT_OLDER + 1
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1 + 1);
        currentTimestamp = block.timestamp;

        newCommitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 1,
            timestamp: uint64(currentTimestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: 0,
            priorityOperationsHash: keccak256(""),
            initialStorageChanges: abi.encodePacked(uint256(0x00000000)),
            repeatedStorageChanges: bytes(""),
            l2Logs: bytes(""),
            l2ArbitraryLengthMessages: new bytes[](0),
            factoryDeps: new bytes[](0)
        });
    }
}
