// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {
    Utils,
    DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    L2_DA_COMMITMENT_SCHEME,
    TEST_ROLLUP_DA_MANAGER_OWNER
} from "../Utils/Utils.sol";
import {ETH_TOKEN_ADDRESS, TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {DummyBaseTokenBridge} from "contracts/dev-contracts/test/DummyBaseTokenBridge.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {DummyChainTypeManagerForValidatorTimelock as DummyCTM} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {FeeParams, PubdataPricingMode, VerifierParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {TestExecutor} from "contracts/dev-contracts/test/TestExecutor.sol";
import {TestCommitter} from "contracts/dev-contracts/test/TestCommitter.sol";
import {UtilsFacet} from "../Utils/UtilsFacet.sol";

import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS, ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {AcceptingVerifier} from "contracts/dev-contracts/test/AcceptingVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {MessageRootBase} from "contracts/core/message-root/MessageRootBase.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";

bytes32 constant EMPTY_PREPUBLISHED_COMMITMENT = 0x0000000000000000000000000000000000000000000000000000000000000000;
bytes constant POINT_EVALUATION_PRECOMPILE_RESULT = hex"000000000000000000000000000000000000000000000000000000000000100073eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001";

contract ExecutorTest is UtilsCallMockerTest {
    address internal owner;
    address internal validator;
    address internal randomSigner;
    address internal l1DAValidator;
    AdminFacet internal admin;
    TestExecutor internal executor;
    TestCommitter internal committer;
    GettersFacet internal getters;
    MailboxFacet internal mailbox;
    // UtilsFacet is attached to every diamond by default (see constructor) so tests can manipulate chain state.
    UtilsFacet internal utilsFacet;
    bytes32 internal newCommittedBlockBatchHash;
    bytes32 internal newCommittedBlockCommitment;
    uint256 internal currentTimestamp;
    CommitBatchInfoZKsyncOS internal newCommitBatchInfoZKsyncOS;
    IExecutor.StoredBatchInfo internal newStoredBatchInfo;
    DummyBaseTokenBridge internal sharedBridge;
    ValidatorTimelock internal validatorTimelock;
    PermissionlessValidator internal permissionlessValidator;
    address internal rollupL1DAValidator;
    L1MessageRoot internal messageRoot;
    DummyBridgehub dummyBridgehub;
    L1ChainAssetHandler internal chainAssetHandler;
    RollupDAManager internal rollupDAManager;
    bytes32 internal baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

    uint256 l2ChainId;

    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    uint256[] internal proofInput;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](14);
        uint256 i = 0;
        selectors[i++] = admin.setPendingAdmin.selector;
        selectors[i++] = admin.acceptAdmin.selector;
        selectors[i++] = admin.setValidator.selector;
        selectors[i++] = admin.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = admin.changeFeeParams.selector;
        selectors[i++] = admin.setTokenMultiplier.selector;
        selectors[i++] = admin.upgradeChainFromVersion.selector;
        selectors[i++] = admin.executeUpgrade.selector;
        selectors[i++] = admin.freezeDiamond.selector;
        selectors[i++] = admin.unfreezeDiamond.selector;
        selectors[i++] = admin.setDAValidatorPair.selector;
        selectors[i++] = admin.makePermanentRollup.selector;
        selectors[i++] = admin.permanentlyAllowPriorityMode.selector;
        selectors[i++] = admin.activatePriorityMode.selector;
        return selectors;
    }

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        uint256 i = 0;
        selectors[i++] = executor.proveBatchesSharedBridge.selector;
        selectors[i++] = executor.executeBatchesSharedBridge.selector;
        selectors[i++] = executor.revertBatchesSharedBridge.selector;
        selectors[i++] = executor.setPriorityTreeStartIndex.selector;
        selectors[i++] = executor.setPriorityTreeHistoricalRoot.selector;
        selectors[i++] = executor.appendPriorityOp.selector;
        return selectors;
    }

    function getCommitterSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        uint256 i = 0;
        selectors[i++] = committer.commitBatchesSharedBridge.selector;
        return selectors;
    }

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](30);
        uint256 i = 0;
        selectors[i++] = getters.getVerifier.selector;
        selectors[i++] = getters.getAdmin.selector;
        selectors[i++] = getters.getPendingAdmin.selector;
        selectors[i++] = getters.getTotalBlocksCommitted.selector;
        selectors[i++] = getters.getTotalBlocksVerified.selector;
        selectors[i++] = getters.getTotalBlocksExecuted.selector;
        selectors[i++] = getters.getTotalPriorityTxs.selector;
        selectors[i++] = getters.getFirstUnprocessedPriorityTx.selector;
        selectors[i++] = getters.getPriorityQueueSize.selector;
        selectors[i++] = getters.getTotalBatchesExecuted.selector;
        selectors[i++] = getters.isValidator.selector;
        selectors[i++] = getters.l2LogsRootHash.selector;
        selectors[i++] = getters.storedBatchHash.selector;
        selectors[i++] = getters.getVerifierParams.selector;
        selectors[i++] = getters.isDiamondStorageFrozen.selector;
        selectors[i++] = getters.getPriorityTxMaxGasLimit.selector;
        selectors[i++] = getters.isEthWithdrawalFinalized.selector;
        selectors[i++] = getters.facets.selector;
        selectors[i++] = getters.facetFunctionSelectors.selector;
        selectors[i++] = getters.facetAddresses.selector;
        selectors[i++] = getters.facetAddress.selector;
        selectors[i++] = getters.isFunctionFreezable.selector;
        selectors[i++] = getters.isFacetFreezable.selector;
        selectors[i++] = getters.getTotalBatchesCommitted.selector;
        selectors[i++] = getters.getTotalBatchesVerified.selector;
        selectors[i++] = getters.storedBlockHash.selector;
        selectors[i++] = getters.isPriorityQueueActive.selector;
        selectors[i++] = getters.getChainTypeManager.selector;
        selectors[i++] = getters.getChainId.selector;
        selectors[i++] = getters.getSemverProtocolVersion.selector;
        return selectors;
    }

    function getMailboxSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        uint256 i = 0;
        selectors[i++] = mailbox.bridgehubRequestL2Transaction.selector;
        selectors[i++] = mailbox.l2TransactionBaseCost.selector;
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

    function deployValidatorTimelock(
        address bridgehubAddr,
        address _initialOwner,
        uint32 _initialExecutionDelay
    ) private returns (address) {
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        ValidatorTimelock timelockImplementation = new ValidatorTimelock(bridgehubAddr);
        return
            address(
                new TransparentUpgradeableProxy(
                    address(timelockImplementation),
                    address(proxyAdmin),
                    abi.encodeCall(ValidatorTimelock.initialize, (_initialOwner, _initialExecutionDelay))
                )
            );
    }

    constructor() {
        uint256 l1ChainID = 1;
        owner = makeAddr("owner");
        validator = makeAddr("validator");
        randomSigner = makeAddr("randomSigner");
        dummyBridgehub = new DummyBridgehub();
        vm.mockCall(address(dummyBridgehub), abi.encodeWithSelector(IL1Bridgehub.L1_CHAIN_ID.selector), abi.encode(1));
        uint256[] memory allZKChainChainIDsZero = new uint256[](0);
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(allZKChainChainIDsZero)
        );
        chainAssetHandler = new L1ChainAssetHandler(owner, address(dummyBridgehub));
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(dummyBridgehub), 1, address(chainAssetHandler))),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        PermissionlessValidator permissionlessValidatorImpl = new PermissionlessValidator();
        TransparentUpgradeableProxy permissionlessValidatorProxy = new TransparentUpgradeableProxy(
            address(permissionlessValidatorImpl),
            makeAddr("permissionlessValidatorProxyAdmin"),
            abi.encodeCall(PermissionlessValidator.initialize, ())
        );
        permissionlessValidator = PermissionlessValidator(address(permissionlessValidatorProxy));

        uint256[] memory allZKChainChainIDs = new uint256[](1);
        allZKChainChainIDs[0] = 271;
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(allZKChainChainIDs)
        );
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainTypeManager.selector),
            abi.encode(makeAddr("chainTypeManager"))
        );
        dummyBridgehub.setMessageRoot(address(messageRoot));
        sharedBridge = new DummyBaseTokenBridge();
        // dummyBridgehub.setChainAssetHandler(address(chainAssetHandler));

        dummyBridgehub.setSharedBridge(address(sharedBridge));
        vm.prank(owner);
        chainAssetHandler.setAddresses();

        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(MessageRootBase.addChainBatchRootV32.selector, 9, 1, bytes32(0)),
            abi.encode()
        );

        l2ChainId = 9;

        rollupL1DAValidator = Utils.deployL1RollupDAValidatorBytecode();
        IEIP7702Checker eip7702Checker = IEIP7702Checker(Utils.deployEIP7702Checker());

        // Deploy and configure RollupDAManager with the DA pair
        rollupDAManager = new RollupDAManager();
        rollupDAManager.updateDAPair(rollupL1DAValidator, L2_DA_COMMITMENT_SCHEME, true);
        rollupDAManager.transferOwnership(TEST_ROLLUP_DA_MANAGER_OWNER);
        vm.prank(TEST_ROLLUP_DA_MANAGER_OWNER);
        rollupDAManager.acceptOwnership();

        admin = new AdminFacet(block.chainid, rollupDAManager);
        getters = new GettersFacet();
        executor = new TestExecutor();
        committer = new TestCommitter();
        mailbox = new MailboxFacet(block.chainid, address(chainAssetHandler), eip7702Checker, false);

        DummyCTM chainTypeManager = new DummyCTM(owner, address(0));
        vm.mockCall(
            address(chainTypeManager),
            abi.encodeWithSelector(IChainTypeManager.protocolVersionIsActive.selector),
            abi.encode(bool(true))
        );
        DiamondInit diamondInit = new DiamondInit();
        AcceptingVerifier testnetVerifier = new AcceptingVerifier();
        // Mock the CTM to return a verifier for protocol version 0
        vm.mockCall(
            address(chainTypeManager),
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, uint256(0)),
            abi.encode(address(testnetVerifier))
        );
        validatorTimelock = ValidatorTimelock(deployValidatorTimelock(address(dummyBridgehub), owner, 0));

        genesisStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: bytes32(""),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: bytes32("")
        });

        InitializeData memory params = InitializeData({
            // TODO REVIEW
            chainId: l2ChainId,
            bridgehub: address(dummyBridgehub),
            chainTypeManager: address(chainTypeManager),
            protocolVersion: 0,
            admin: owner,
            validatorTimelock: address(validatorTimelock),
            baseTokenAssetId: baseTokenAssetId,
            storedBatchZero: keccak256(abi.encode(genesisStoredBatchInfo))
        });
        mockDiamondInitInteropCenterCallsWithAddress(
            address(dummyBridgehub),
            address(0),
            baseTokenAssetId,
            address(chainTypeManager),
            address(permissionlessValidator)
        );

        bytes memory diamondInitData = abi.encodeWithSelector(diamondInit.initialize.selector, params);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](6);
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
            facet: address(committer),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getCommitterSelectors()
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: address(getters),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getGettersSelectors()
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: address(mailbox),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getMailboxSelectors()
        });
        facetCuts[5] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitData
        });

        uint256 chainId = block.chainid;
        DiamondProxy diamondProxy = new DiamondProxy(chainId, diamondCutData);

        executor = TestExecutor(address(diamondProxy));
        committer = TestCommitter(address(diamondProxy));
        getters = GettersFacet(address(diamondProxy));
        mailbox = MailboxFacet(address(diamondProxy));
        admin = AdminFacet(address(diamondProxy));
        utilsFacet = UtilsFacet(address(diamondProxy));
        chainTypeManager.setZKChain(l2ChainId, address(diamondProxy));

        // Initiate the token multiplier to enable L1 -> L2 transactions.
        vm.prank(address(chainTypeManager));
        admin.setTokenMultiplier(1, 1);
        vm.prank(address(owner));
        admin.setDAValidatorPair(address(rollupL1DAValidator), L2_DA_COMMITMENT_SCHEME);

        // Allow to call executor directly, without going through ValidatorTimelock
        vm.prank(address(chainTypeManager));
        admin.setValidator(address(validator), true);

        // foundry's default value is 1 for the block's timestamp, it is expected
        // that block.timestamp > COMMIT_TIMESTAMP_NOT_OLDER + 1
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1 + 1);
        currentTimestamp = block.timestamp;

        newCommitBatchInfoZKsyncOS = CommitBatchInfoZKsyncOS({
            batchNumber: 1,
            newStateCommitment: Utils.randomBytes32("newStateCommitment"),
            numberOfLayer1Txs: 0,
            numberOfLayer2Txs: 0,
            priorityOperationsHash: keccak256(""),
            dependencyRootsRollingHash: keccak256(""),
            l2LogsTreeRoot: bytes32(""),
            daCommitmentScheme: L2_DA_COMMITMENT_SCHEME,
            daCommitment: bytes32(""),
            firstBlockTimestamp: uint64(currentTimestamp),
            firstBlockNumber: uint64(1),
            lastBlockTimestamp: uint64(currentTimestamp),
            lastBlockNumber: uint64(2),
            chainId: l2ChainId,
            operatorDAInput: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            slChainId: block.chainid
        });

        dummyBridgehub.setZKChain(l2ChainId, address(diamondProxy));

        vm.prank(owner);
        validatorTimelock.addValidatorForChainId(l2ChainId, validator);

        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IAssetRouterShared.bridgehubDepositBaseToken.selector),
            abi.encode(true)
        );
    }

    /// @dev Mocks the rollup L1 DA validator's `checkDA` for the given batch: an all-zero blob
    /// output, which the ZKsync OS commit path accepts (it verifies DA out of band).
    function _mockDAForCommit(uint256 batchNumber) internal {
        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        L1DAValidatorOutput memory daOutput = L1DAValidatorOutput({
            stateDiffHash: bytes32(0),
            blobsLinearHashes: blobHashes,
            blobsOpeningCommitments: blobCommitments
        });
        // Match any checkDA call for this batch regardless of DA input encoding
        vm.mockCall(
            rollupL1DAValidator,
            abi.encodeWithSelector(IL1DAValidator.checkDA.selector, l2ChainId, batchNumber),
            abi.encode(daOutput)
        );
    }

    /// @dev Commits one ZKsync OS batch through the real committer (DA mocked via
    /// {_mockDAForCommit}) and reconstructs the resulting `StoredBatchInfo`. The cryptographic
    /// fields (`batchHash`, `commitment`) are read back from the emitted `BlockCommit` event; the
    /// reconstruction is self-checking because any later prove/execute recomputes the stored hash.
    function _commitOSBatchGetStored(
        IExecutor.StoredBatchInfo memory prev,
        CommitBatchInfoZKsyncOS memory info
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        _mockDAForCommit(info.batchNumber);

        CommitBatchInfoZKsyncOS[] memory arr = new CommitBatchInfoZKsyncOS[](1);
        arr[0] = info;
        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesDataZKsyncOS(
            prev,
            arr
        );
        vm.recordLogs();
        vm.prank(validator);
        committer.commitBatchesSharedBridge(address(0), commitFrom, commitTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 batchHash;
        bytes32 commitment;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == ICommitter.BlockCommit.selector) {
                batchHash = entries[i].topics[2];
                commitment = entries[i].topics[3];
                break;
            }
        }
        require(commitment != bytes32(0), "BlockCommit event not found");

        stored = IExecutor.StoredBatchInfo({
            batchNumber: info.batchNumber,
            batchHash: batchHash,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: info.numberOfLayer1Txs,
            priorityOperationsHash: info.priorityOperationsHash,
            dependencyRootsRollingHash: info.dependencyRootsRollingHash,
            l2LogsTreeRoot: info.l2LogsTreeRoot,
            timestamp: 0,
            commitment: commitment
        });
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
