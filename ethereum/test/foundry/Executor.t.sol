// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../cache/solpp-generated-contracts/common/AllowList.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Executor.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Governance.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Mailbox.sol";
import "../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import "../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";

contract ExecutorTest is Test {
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
    }
}

contract AuthorizationTest is ExecutorTest {
    IExecutor.StoredBlockInfo storedBlockInfo;
    IExecutor.CommitBlockInfo commitBlockInfo;

    function setUp() public {
        storedBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: keccak256(bytes.concat("randomBytes32", "setUp()", "0")),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "1")
            ),
            timestamp: 0,
            commitment: keccak256(bytes.concat("randomBytes32", "setUp()", "2"))
        });

        commitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 0,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "3")
            ),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "4")
            ),
            priorityOperationsHash: keccak256(""),
            initialStorageChanges: bytes(""),
            repeatedStorageChanges: bytes(""),
            l2Logs: bytes(""),
            l2ArbitraryLengthMessages: new bytes[](0),
            factoryDeps: new bytes[](0)
        });
    }

    function test_revertWhen_commitingByUnauthorisedAddress() public {
        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = commitBlockInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.commitBlocks(storedBlockInfo, commitBlockInfoArray);
    }

    function test_revertWhen_provingByUnauthorisedAddress() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = storedBlockInfo;

        vm.prank(owner);

        vm.expectRevert(bytes.concat("1h"));
        executor.proveBlocks(storedBlockInfo, storedBlockInfoArray, proofInput);
    }

    function test_revertWhen_executingByUnauthorizedAddress() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = storedBlockInfo;

        vm.prank(randomSigner);

        vm.expectRevert(bytes.concat("1h"));
        executor.executeBlocks(storedBlockInfoArray);
    }
}

contract CommittingFunctionalityTest is ExecutorTest {
    function setUp() public {
        // foundry's default value is 1 for the block's timestamp, it is expected
        // that block.timestamp > COMMIT_TIMESTAMP_NOT_OLDER
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;
        newCommitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 1,
            timestamp: uint64(currentTimestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "0")
            ),
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

    function test_revertWhen_comittingWithWrongLastCommittedBlockData() public {
        IExecutor.CommitBlockInfo[]
            memory newCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        newCommitBlockInfoArray[0] = newCommitBlockInfo;

        IExecutor.StoredBlockInfo
            memory wrongGenesisStoredBlockInfo = genesisStoredBlockInfo;
        wrongGenesisStoredBlockInfo.timestamp = 1000;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("i"));
        executor.commitBlocks(
            wrongGenesisStoredBlockInfo,
            newCommitBlockInfoArray
        );
    }

    function test_revertWhen_comittingWithWrongOrderOfBlocks() public {
        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.blockNumber = 2; // wrong block number

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("f"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongNewBlockTimestamp() public {
        bytes32 wrongNewBlockTimestamp = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongNewBlockTimestamp()",
                "0"
            )
        );
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            wrongNewBlockTimestamp,
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("tb"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithTooSmallNewBlockTimestamp() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            address(L2_SYSTEM_CONTEXT_ADDRESS),
            bytes32(0),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.timestamp = 0;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingTooBigNewBlockTimestamp() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            address(L2_SYSTEM_CONTEXT_ADDRESS),
            uint256(0xffffffff),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.timestamp = 0xffffffff;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h1"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongPreviousBlockHash() public {
        bytes32 wrongPreviousBlockHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongPreviousBlockHash()",
                "0"
            )
        );
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            wrongPreviousBlockHash
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("l"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithoutProcessingSystemContextLog()
        public
    {
        bytes memory wrongL2Logs = abi.encodePacked(bytes4(0x00000000));

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("by"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithProcessingSystemContextLogTwice()
        public
    {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("fx"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_reverWhen_unexpectedL1ToL2Log() public {
        address unexpectedAddress = address(0);
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            unexpectedAddress,
            uint256(currentTimestamp)
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ne"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongCanonicalTxHash() public {
        bytes32 randomBytes32 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongCanonicalTxHash()",
                "0"
            )
        );
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            randomBytes32,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("t"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongNumberOfLayer1txs() public {
        bytes32 arbitraryCanonicalTxHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongNumberOfLayer1txs()",
                "0"
            )
        );
        bytes32 chainedPriorityTxHash = keccak256(
            bytes.concat(keccak256(""), arbitraryCanonicalTxHash)
        );

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            arbitraryCanonicalTxHash,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.priorityOperationsHash = bytes32(
            chainedPriorityTxHash
        );
        wrongNewCommitBlockInfo.numberOfLayer1Txs = 2;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ta"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongFactoryDepsData() public {
        bytes32 randomFactoryDeps0 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongFactoryDepsData()",
                "0"
            )
        );
        bytes32 randomFactoryDeps1 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongFactoryDepsData()",
                "1"
            )
        );

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            randomFactoryDeps0
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("k3"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongFactoryDepsArrayLength()
        public
    {
        bytes32 arbitraryBytecode = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingWithWrongFactoryDepsArrayLength()",
                "0"
            )
        );
        bytes32 arbitraryBytecodeHash = sha256(bytes.concat(arbitraryBytecode));
        uint256 arbitraryBytecodeHashManipulated1 = uint256(
            arbitraryBytecodeHash
        ) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        uint256 arbitraryBytecodeHashManipulated2 = arbitraryBytecodeHashManipulated1 |
                0x0100000100000000000000000000000000000000000000000000000000000000;

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            uint256(arbitraryBytecodeHashManipulated2)
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes[] memory factoryDeps = new bytes[](2);
        factoryDeps[0] = bytes.concat(arbitraryBytecode);
        factoryDeps[1] = bytes.concat(arbitraryBytecode);

        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ym"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_comittingWithWrongHashedMessage() public {
        bytes32 randomL2LogValue = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_comittingWithWrongHashedMessage()",
                "0"
            )
        );

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_TO_L1_MESSENGER,
            bytes32(""),
            randomL2LogValue
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes32 randomL2Message = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_comittingWithWrongHashedMessage()",
                "1"
            )
        );

        bytes[] memory l2ArbitraryLengthMessages = new bytes[](1);
        l2ArbitraryLengthMessages[0] = bytes.concat(randomL2Message);

        wrongNewCommitBlockInfo
            .l2ArbitraryLengthMessages = l2ArbitraryLengthMessages;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("k2"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongNumberOfMessages() public {
        bytes memory arbitraryMessage = abi.encodePacked(uint8(0xaa));
        bytes32 arbitraryHashedMessage = keccak256(arbitraryMessage);

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_TO_L1_MESSENGER,
            bytes32(""),
            arbitraryHashedMessage
        );

        bytes[] memory l2ArbitraryLengthMessagesArray = new bytes[](2);
        l2ArbitraryLengthMessagesArray[0] = arbitraryMessage;
        l2ArbitraryLengthMessagesArray[1] = arbitraryMessage;

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;

        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo
            .l2ArbitraryLengthMessages = l2ArbitraryLengthMessagesArray;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("pl"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongBytecodeLength() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_revertWhen_committingWithWrongBytecodeLength()",
                    "0"
                )
            )
        );

        bytes20 randomFactoryDeps1 = bytes20(
            keccak256(
                bytes.concat(
                    "randomBytes20",
                    "test_revertWhen_committingWithWrongBytecodeLength()",
                    "0"
                )
            )
        );
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("bl"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongNumberOfWordsInBytecode()
        public
    {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_revertWhen_committingWithWrongNumberOfWordsInBytecode()",
                    "0"
                )
            )
        );

        bytes memory randomFactoryDeps1 = bytes.concat(
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_revertWhen_committingWithWrongNumberOfWordsInBytecode()",
                    "0"
                )
            ),
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_revertWhen_committingWithWrongNumberOfWordsInBytecode()",
                    "1"
                )
            )
        );

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pr"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithWrongRepeatedStorageWrites() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.indexRepeatedStorageChanges = 0;
        wrongNewCommitBlockInfo.initialStorageChanges = "0x00000001";

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("yq"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_revertWhen_committingWithTooLongL2Logs() public {
        // uint256 constant MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES = 4 + L2_TO_L1_LOG_SERIALIZE_SIZE * 512;
        bytes memory arr1;

        for (uint i = 0; i < 512; i++) {
            arr1 = abi.encodePacked(
                arr1,
                bytes4(0x00000000),
                L2_TO_L1_MESSENGER,
                bytes32(""),
                keccak256("")
            );
        }

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            arr1
        );

        bytes[] memory l2ArbitraryLengthMessages = new bytes[](512);

        for (uint i = 0; i < l2ArbitraryLengthMessages.length; i++) {
            l2ArbitraryLengthMessages[i] = bytes("");
        }

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo
            .l2ArbitraryLengthMessages = l2ArbitraryLengthMessages;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pu"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_shouldCommitBlock() public {
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        newCommitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = newCommitBlockInfo;

        vm.prank(validator);

        vm.recordLogs();

        executor.commitBlocks(genesisStoredBlockInfo, commitBlockInfoArray);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(
            entries[0].topics[0],
            keccak256("BlockCommit(uint256,bytes32,bytes32)")
        );
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // blockNumber
        assertEq(
            entries[0].topics[2],
            bytes32(
                0x5391aedfa307cfbb5523d0ba566759d1b5c0901dcb5868a195addafd5e9dd563
            )
        ); // blockHash
        assertEq(
            entries[0].topics[3],
            bytes32(
                0x00cc2f6937a02033a72880ac0f2a2a7caeb8795676538437e1277d2b6e6c6fb5
            )
        ); // commitment

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 1);
    }
}

contract ProvingTest is ExecutorTest {
    function setUp() public {
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;
        IExecutor.CommitBlockInfo memory commitBlockInfo = IExecutor
            .CommitBlockInfo({
                blockNumber: 1,
                timestamp: uint64(currentTimestamp),
                indexRepeatedStorageChanges: 0,
                newStateRoot: keccak256(
                    bytes.concat("randomBytes32", "setUp()", "0")
                ),
                numberOfLayer1Txs: 0,
                l2LogsTreeRoot: 0,
                priorityOperationsHash: keccak256(""),
                initialStorageChanges: abi.encodePacked(uint256(0x00000000)),
                repeatedStorageChanges: bytes(""),
                l2Logs: bytes(""),
                l2ArbitraryLengthMessages: new bytes[](0),
                factoryDeps: new bytes[](0)
            });

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        commitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = commitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(genesisStoredBlockInfo, commitBlockInfoArray);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: entries[0].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[0].topics[3]
        });
    }

    function test_revertWhen_provingWithWrongPreviousBlockData() public {
        IExecutor.StoredBlockInfo
            memory wrongPreviousStoredBlockInfo = genesisStoredBlockInfo;
        wrongPreviousStoredBlockInfo.blockNumber = 10; // Correct is 0

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("t1"));
        executor.proveBlocks(
            wrongPreviousStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );
    }

    function test_revertWhen_provingWithWrongCommittedBlock() public {
        IExecutor.StoredBlockInfo
            memory wrongNewStoredBlockInfo = newStoredBlockInfo;
        wrongNewStoredBlockInfo.blockNumber = 10; // Correct is 1

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = wrongNewStoredBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("o1"));
        executor.proveBlocks(
            genesisStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );
    }

    function test_revertWhen_provingRevertedBlockWithoutCommittingAgain()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("q"));
        executor.proveBlocks(
            genesisStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );
    }

    function test_successfulProve() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);

        executor.proveBlocks(
            genesisStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 1);
    }
}

contract RevertingTest is ExecutorTest {
    function setUp() public {
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;
        IExecutor.CommitBlockInfo memory commitBlockInfo = IExecutor
            .CommitBlockInfo({
                blockNumber: 1,
                timestamp: uint64(currentTimestamp),
                indexRepeatedStorageChanges: 0,
                newStateRoot: keccak256(
                    bytes.concat("randomBytes32", "setUp()", "0")
                ),
                numberOfLayer1Txs: 0,
                l2LogsTreeRoot: 0,
                priorityOperationsHash: keccak256(""),
                initialStorageChanges: abi.encodePacked(uint256(0x00000000)),
                repeatedStorageChanges: bytes(""),
                l2Logs: bytes(""),
                l2ArbitraryLengthMessages: new bytes[](0),
                factoryDeps: new bytes[](0)
            });

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        commitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = commitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(genesisStoredBlockInfo, commitBlockInfoArray);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: entries[0].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[0].topics[3]
        });

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);

        executor.proveBlocks(
            genesisStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );
    }

    function test_revertWhen_revertingMoreBlocksThanAlreadyCommitted() public {
        vm.prank(validator);
        vm.expectRevert(bytes.concat("v1"));
        executor.revertBlocks(10);
    }

    function test_successfulRevert() public {
        uint256 totalBlocksCommittedBefore = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommittedBefore, 1, "totalBlocksCommittedBefore");

        uint256 totalBlocksVerifiedBefore = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerifiedBefore, 1, "totalBlocksVerifiedBefore");

        vm.prank(validator);
        executor.revertBlocks(0);

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 0, "totalBlocksCommitted");

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 0, "totalBlocksVerified");
    }
}

contract ExecutingTest is ExecutorTest {
    function setUp() public {
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;
        newCommitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 1,
            timestamp: uint64(currentTimestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "0")
            ),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: 0,
            priorityOperationsHash: keccak256(""),
            initialStorageChanges: abi.encodePacked(uint256(0x00000000)),
            repeatedStorageChanges: bytes(""),
            l2Logs: bytes(""),
            l2ArbitraryLengthMessages: new bytes[](0),
            factoryDeps: new bytes[](0)
        });

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );
        newCommitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = newCommitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(genesisStoredBlockInfo, commitBlockInfoArray);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: entries[0].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[0].topics[3]
        });

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);
        executor.proveBlocks(
            genesisStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );
    }

    function test_revertWhen_executingBlockWithWrongBlockNumber() public {
        IExecutor.StoredBlockInfo
            memory wrongNewStoredBlockInfo = newStoredBlockInfo;
        wrongNewStoredBlockInfo.blockNumber = 10; // Correct is 1

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = wrongNewStoredBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("k"));
        executor.executeBlocks(storedBlockInfoArray);
    }

    function test_revertWhen_executingBlockWithWrongData() public {
        IExecutor.StoredBlockInfo
            memory wrongNewStoredBlockInfo = newStoredBlockInfo;
        wrongNewStoredBlockInfo.timestamp = 0; // incorrect timestamp

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = wrongNewStoredBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("exe10"));
        executor.executeBlocks(storedBlockInfoArray);
    }

    function test_revertWhen_executingRevertedBlockWithoutCommittingAndProvingAgain()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("n"));
        executor.executeBlocks(storedBlockInfoArray);
    }

    function test_revertWhen_executingUnavailablePriorityOperationHash()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        bytes32 arbitraryCanonicalTxHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_executingUnavailablePriorityOperationHash()",
                "0"
            )
        );
        bytes32 chainedPriorityTxHash = keccak256(
            bytes.concat(keccak256(""), arbitraryCanonicalTxHash)
        );

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            arbitraryCanonicalTxHash,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;
        correctNewCommitBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewCommitBlockInfo.numberOfLayer1Txs = 1;

        IExecutor.CommitBlockInfo[]
            memory correctNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        correctNewCommitBlockInfoArray[0] = correctNewCommitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(
            genesisStoredBlockInfo,
            correctNewCommitBlockInfoArray
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBlockInfo
            memory correctNewStoredBlockInfo = newStoredBlockInfo;
        correctNewStoredBlockInfo.blockHash = entries[0].topics[2];
        correctNewStoredBlockInfo.numberOfLayer1Txs = 1;
        correctNewStoredBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewStoredBlockInfo.commitment = entries[0].topics[3];

        IExecutor.StoredBlockInfo[]
            memory correctNewStoredBlockInfoArray = new IExecutor.StoredBlockInfo[](
                1
            );
        correctNewStoredBlockInfoArray[0] = correctNewStoredBlockInfo;

        vm.prank(validator);
        executor.proveBlocks(
            genesisStoredBlockInfo,
            correctNewStoredBlockInfoArray,
            proofInput
        );

        vm.prank(validator);
        vm.expectRevert(bytes.concat("s"));
        executor.executeBlocks(correctNewStoredBlockInfoArray);
    }

    function test_revertWhen_executingWithUnmatchedPriorityOperationHash()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        bytes32 arbitraryCanonicalTxHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_executingWithUnmatchedPriorityOperationHash()",
                "0"
            )
        );
        bytes32 chainedPriorityTxHash = keccak256(
            bytes.concat(keccak256(""), arbitraryCanonicalTxHash)
        );

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            arbitraryCanonicalTxHash,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;
        correctNewCommitBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewCommitBlockInfo.numberOfLayer1Txs = 1;

        IExecutor.CommitBlockInfo[]
            memory correctNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        correctNewCommitBlockInfoArray[0] = correctNewCommitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(
            genesisStoredBlockInfo,
            correctNewCommitBlockInfoArray
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBlockInfo
            memory correctNewStoredBlockInfo = newStoredBlockInfo;
        correctNewStoredBlockInfo.blockHash = entries[0].topics[2];
        correctNewStoredBlockInfo.numberOfLayer1Txs = 1;
        correctNewStoredBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewStoredBlockInfo.commitment = entries[0].topics[3];

        IExecutor.StoredBlockInfo[]
            memory correctNewStoredBlockInfoArray = new IExecutor.StoredBlockInfo[](
                1
            );
        correctNewStoredBlockInfoArray[0] = correctNewStoredBlockInfo;

        vm.prank(validator);
        executor.proveBlocks(
            genesisStoredBlockInfo,
            correctNewStoredBlockInfoArray,
            proofInput
        );

        bytes32 randomFactoryDeps0 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_executingWithUnmatchedPriorityOperationHash()",
                "1"
            )
        );

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps0);

        uint256 gasPrice = 1000000000;
        uint256 l2GasLimit = 1000000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        uint256 l2Value = 10 ether;
        uint256 totalCost = baseCost + l2Value;

        mailbox.requestL2Transaction{value: totalCost}(
            address(0),
            l2Value,
            bytes(""),
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps,
            address(0)
        );

        vm.prank(validator);
        vm.expectRevert(bytes.concat("x"));
        executor.executeBlocks(correctNewStoredBlockInfoArray);
    }

    function test_revertWhen_committingBlockWithWrongPreviousBlockHash()
        public
    {
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory correctNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        correctNewCommitBlockInfoArray[0] = correctNewCommitBlockInfo;

        bytes32 wrongPreviousBlockHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_revertWhen_committingBlockWithWrongPreviousBlockHash()",
                "0"
            )
        );

        IExecutor.StoredBlockInfo memory genesisBlock = genesisStoredBlockInfo;
        genesisBlock.blockHash = wrongPreviousBlockHash;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("i"));
        executor.commitBlocks(genesisBlock, correctNewCommitBlockInfoArray);
    }

    function test_shouldExecuteBlockSuccessfully() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);
        executor.executeBlocks(storedBlockInfoArray);

        uint256 totalBlocksExecuted = getters.getTotalBlocksExecuted();
        assertEq(totalBlocksExecuted, 1);
    }
}
