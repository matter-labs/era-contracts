pragma solidity 0.8.24;

import {Vm} from "forge-std/Test.sol";

import {Utils, L2_SYSTEM_CONTEXT_ADDRESS, L2_BOOTLOADER_ADDRESS} from "test/foundry/unit/concrete/Utils/Utils.sol";
import {StateTransitionManagerTest} from "test/foundry/unit/concrete/state-transition/StateTransitionManager/_StateTransitionManager_Shared.t.sol";

import {COMMIT_TIMESTAMP_NOT_OLDER, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {InitializeData, DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {CustomUpgradeTest} from "contracts/dev-contracts/test/CustomUpgradeTest.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, SYSTEM_UPGRADE_L2_TX_TYPE, PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
import {GettersFacetWrapper} from "test/foundry/unit/concrete/state-transition/chain-deps/facets/Getters/_Getters_Shared.t.sol";
import {console2 as console} from "forge-std/Script.sol";
import {ZeroAddress, LogAlreadyProcessed, PubdataGreaterThanLimit, TxHashMismatch, TimeNotReached, L2BytecodeHashMismatch, InvalidTxType, NewProtocolMajorVersionNotZero, ProtocolVersionTooSmall, L2UpgradeNonceNotEqualToNewProtocolVersion, MissingSystemLogs, TxnBodyGasLimitNotEnoughGas, PatchUpgradeCantSetBootloader, PatchUpgradeCantSetDefaultAccount, PatchCantSetUpgradeTxn, ProtocolVersionMinorDeltaTooBig, TooMuchGas, TooManyFactoryDeps, UnexpectedNumberOfFactoryDeps, PreviousUpgradeNotFinalized} from "../../../contracts/common/L1ContractErrors.sol";

contract L2UpgradeTest is Test {
    uint32 internal major;
    uint32 internal minor;
    uint32 internal patch;
    uint256 internal initialProtocolVersion;
    address newChainAddress;
    DiamondInit internal initializeDiamond;
    // Items for logs & commits
    uint256 internal currentTimestamp;
    IExecutor.CommitBatchInfo internal newCommitBatchInfo;
    IExecutor.StoredBatchInfo internal newStoredBatchInfo;
    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    IExecutor.ProofInput internal proofInput;

    // Facets exposing the diamond
    AdminFacet internal adminFacet;
    ExecutorFacet internal executorFacet;
    GettersFacet internal gettersFacet;

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
    address internal newChainAdmin;
    uint256 chainId = block.chainid;
    address internal testnetVerifier = address(new TestnetVerifier());

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(bridgehub);
        stateTransitionManager = new StateTransitionManager(bridgehub, type(uint256).max);
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
                selectors: gettersSelectors()
            })
        );

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        StateTransitionManagerInitializeData memory stmInitializeDataNoGovernor = StateTransitionManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeDataNoGovernor)
        );

        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
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

        createNewChain(getDiamondCutData(address(diamondInit)));
        initializeDiamond = new DiamondInit();
        newChainAddress = chainContractAddress.getHyperchain(chainId);

        executorFacet = ExecutorFacet(address(newChainAddress));
        gettersFacet = GettersFacet(address(newChainAddress));
        adminFacet = AdminFacet(address(newChainAddress));

        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();

        initialProtocolVersion = packSemver(major, minor, patch);

        // Initial setup for logs & commits
        vm.stopPrank();
        vm.startPrank(newChainAdmin);

        genesisStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: bytes32(uint256(0x01)),
            indexRepeatedStorageChanges: 1,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: bytes32(uint256(0x01))
        });

        adminFacet.setTokenMultiplier(1, 1);

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
            indexRepeatedStorageChanges: 1,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            bootloaderHeapInitialContentsHash: Utils.randomBytes32("bootloaderHeapInitialContentsHash"),
            eventsQueueStateHash: Utils.randomBytes32("eventsQueueStateHash"),
            systemLogs: l2Logs,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        // Commit & prove batches
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes32 expectedSystemContractUpgradeTxHash = gettersFacet.getL2SystemContractsUpgradeTxHash();
        bytes[] memory correctL2Logs = Utils.createSystemLogsWithUpgradeTransaction(
            expectedSystemContractUpgradeTxHash
        );

        correctL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        correctL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(uint256(0x01))
        );

        l2Logs = Utils.encodePacked(correctL2Logs);
        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.systemLogs = l2Logs;

        IExecutor.CommitBatchInfo[] memory commitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;

        vm.stopPrank();
        vm.startPrank(validator);
        vm.recordLogs();
        executorFacet.commitBatches(genesisStoredBatchInfo, commitBatchInfoArray);

        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;

        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });
        executorFacet.proveBatches(genesisStoredBatchInfo, storedBatch1InfoChainIdUpgrade, proofInput);

        executorFacet.executeBatches(storedBatch1InfoChainIdUpgrade);
    }

    function test_upgradeWhenNotAllBatchesAreExecuted() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
        assertEq(gettersFacet.getProtocolVersion(), initialProtocolVersion);
        assertEq(
            gettersFacet.getL2SystemContractsUpgradeTxHash(),
            0x0000000000000000000000000000000000000000000000000000000000000000
        );

        uint256 oldProtocolVersion = gettersFacet.getProtocolVersion();
        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: oldProtocolVersion + 1
        });

        executeUpgrade(false, "", proposedUpgrade);
        assertEq(gettersFacet.getProtocolVersion(), initialProtocolVersion + 1);
    }

    function test_patchOnlyUpgradeCannotSetDefaultAccount() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch + 1);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0100010100000000000000000000000000000000000000000000000000000010,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(PatchUpgradeCantSetDefaultAccount.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_patchOnlyUpgradeCannotSetBootloader() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch + 1);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0100010100000000000000000000000000000000000000000000000000000010,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(PatchUpgradeCantSetBootloader.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_patchOnlyUpgradeCannotUpgradeTransaction() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch + 1);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.nonce = 0;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(PatchCantSetUpgradeTxn.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_majorVersionChange() public {
        uint256 protocolVersion = 18446744073709551616;

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.nonce = 0;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(NewProtocolMajorVersionNotZero.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_futureTimestamp() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: COMMIT_TIMESTAMP_NOT_OLDER + 10,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(
            TimeNotReached.selector,
            proposedUpgrade.upgradeTimestamp,
            COMMIT_TIMESTAMP_NOT_OLDER + 1
        );
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_incorrectTxType() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.txType = 255;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(InvalidTxType.selector, l2ProtocolUpgradeTx.txType);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_newProtocolVersionAsPartOfNonce() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
        bytes32 newCommitment = 0x14f98eb4c8ea8862b2483259641d6dcebf8b2507bf378e62c1af31674bf861d2;
        IExecutor.StoredBatchInfo[] memory newStoredBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        newStoredBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: batch2Info[0].batchNumber,
            batchHash: batch2Info[0].newStateRoot,
            indexRepeatedStorageChanges: batch2Info[0].indexRepeatedStorageChanges,
            numberOfLayer1Txs: batch2Info[0].numberOfLayer1Txs,
            priorityOperationsHash: batch2Info[0].priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: batch2Info[0].timestamp,
            commitment: newCommitment
        });

        executorFacet.proveBatches(storedBatch1InfoChainIdUpgrade[0], newStoredBatch1InfoChainIdUpgrade, proofInput);
        executorFacet.executeBatches(newStoredBatch1InfoChainIdUpgrade);

        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        bytes32 bootloaderHash = bytes32(0);
        bytes32 defaultAccountHash = bytes32(0);
        address verifier = makeAddr("verifier");
        VerifierParams memory verifierParams = Utils.makeVerifierParams();
        bytes32 factoryDep = Utils.randomBytes32("myFactoryDep");
        bytes[] memory myFactoryDep = new bytes[](1);
        myFactoryDep[0] = abi.encode(factoryDep);
        uint256[] memory myFactoryDepHash = new uint256[](1);
        myFactoryDepHash[0] = uint256(factoryDep);
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.factoryDeps = myFactoryDepHash;
        upgradeTx.nonce = 2;
        upgradeTx.txType = 254;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: myFactoryDep,
            bootloaderHash: bootloaderHash,
            defaultAccountHash: defaultAccountHash,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        bytes memory revertMsg = abi.encodeWithSelector(
            L2UpgradeNonceNotEqualToNewProtocolVersion.selector,
            upgradeTx.nonce,
            1
        );
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_monotonicProtocolVersion() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(ProtocolVersionTooSmall.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_protocolVersionIncreasingTooMuch() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1000, patch);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(ProtocolVersionMinorDeltaTooBig.selector, 100, 1000);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_notEnoughGas() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.nonce = 0;
        l2ProtocolUpgradeTx.gasLimit = 0;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(TxnBodyGasLimitNotEnoughGas.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_tooBigGasLimit() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.nonce = 0;
        l2ProtocolUpgradeTx.gasLimit = 1000000000;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(TooMuchGas.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_cannotOutputMorePubdataThanProcessable() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.nonce = 0;
        l2ProtocolUpgradeTx.gasLimit = 1000000;
        l2ProtocolUpgradeTx.gasPerPubdataByteLimit = 2;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(PubdataGreaterThanLimit.selector, 99000, 495000);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_incorrectFactoryDepsHash() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        uint256[] memory factoryHash = new uint256[](1);
        factoryHash[0] = uint256(Utils.randomBytes32("FactoryHash"));
        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.factoryDeps = factoryHash;
        l2ProtocolUpgradeTx.txType = SYSTEM_UPGRADE_L2_TX_TYPE;
        l2ProtocolUpgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        l2ProtocolUpgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        l2ProtocolUpgradeTx.nonce = minor + 1;

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(Utils.randomBytes32("FactoryDeps"));

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        console.log(factoryHash[0]);
        console.logBytes(factoryDeps[0]);
        bytes memory revertMsg = abi.encodeWithSelector(
            L2BytecodeHashMismatch.selector,
            0x01000001b32f2d7374a0d4c6a6963811a3ba2a1fde5468b290cf01523c939025,
            0x68958563f7e4d37cd700e1be8e9a685dbadaa1c5f3f8eb062c6d0eed74525308
        );
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_tooShortFactoryDeps() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        uint256[] memory factoryHashes = new uint256[](2);
        factoryHashes[0] = uint256(Utils.randomBytes32("FactoryHashes"));
        factoryHashes[1] = uint256(Utils.randomBytes32("FactoryHashes2"));
        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.factoryDeps = factoryHashes;
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        l2ProtocolUpgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        l2ProtocolUpgradeTx.nonce = minor + 1;

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(Utils.randomBytes32("FactoryDeps"));

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
        bytes memory revertMsg = abi.encodeWithSelector(UnexpectedNumberOfFactoryDeps.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_tooLongFactoryDepsArray() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor + 1, patch);

        uint256[] memory factoryHashes = new uint256[](33);
        L2CanonicalTransaction memory l2ProtocolUpgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        l2ProtocolUpgradeTx.factoryDeps = factoryHashes;
        l2ProtocolUpgradeTx.txType = 254;
        l2ProtocolUpgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        l2ProtocolUpgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        l2ProtocolUpgradeTx.nonce = minor + 1;

        bytes[] memory factoryDeps = new bytes[](33);

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });

        bytes memory revertMsg = abi.encodeWithSelector(TooManyFactoryDeps.selector);
        executeUpgrade(true, revertMsg, proposedUpgrade);
    }

    function test_executeSuccessfulUpgrade() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        bytes32 bootloaderHash = 0x0100010100000000000000000000000000000000000000000000000000000010;
        bytes32 defaultAccountHash = 0x0100010100000000000000000000000000000000000000000000000000000010;
        address verifier = makeAddr("verifier");
        uint256[] memory factoryHash = new uint256[](1);
        factoryHash[0] = uint256(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(0x0000000000000000000000000000000000000000000000000000000000000000);

        VerifierParams memory verifierParams = Utils.makeVerifierParams();
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.nonce = minor + 1;
        upgradeTx.txType = 254;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        upgradeTx.factoryDeps = factoryHash;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: bootloaderHash,
            defaultAccountHash: defaultAccountHash,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        executeUpgrade(false, "", proposedUpgrade);

        assertEq(gettersFacet.getL2BootloaderBytecodeHash(), bootloaderHash);
        assertEq(gettersFacet.getL2DefaultAccountBytecodeHash(), defaultAccountHash);
        assertEq(gettersFacet.getVerifier(), verifier);
        assertEq(gettersFacet.getProtocolVersion(), newProtocolVersion);

        VerifierParams memory newVerifierParams = gettersFacet.getVerifierParams();
        assertEq(verifierParams.recursionNodeLevelVkHash, newVerifierParams.recursionNodeLevelVkHash);
        assertEq(verifierParams.recursionLeafLevelVkHash, newVerifierParams.recursionLeafLevelVkHash);
        assertEq(verifierParams.recursionCircuitsSetVksHash, newVerifierParams.recursionCircuitsSetVksHash);
    }

    function test_successfullyPerformPatchUpgradeWithPendingMinorUpgrade() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        bytes32 bootloaderHash = 0x0100010100000000000000000000000000000000000000000000000000000010;
        bytes32 defaultAccountHash = 0x0100010100000000000000000000000000000000000000000000000000000010;
        address verifier = makeAddr("verifier");
        uint256[] memory factoryHash = new uint256[](1);
        factoryHash[0] = uint256(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(0x0000000000000000000000000000000000000000000000000000000000000000);

        VerifierParams memory verifierParams = Utils.makeVerifierParams();
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.nonce = minor + 1;
        upgradeTx.txType = 254;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        upgradeTx.factoryDeps = factoryHash;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: bootloaderHash,
            defaultAccountHash: defaultAccountHash,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        executeUpgrade(false, "", proposedUpgrade);

        upgradeTx.txType = 0;
        newProtocolVersion = packSemver(major, minor + 1, patch + 1);
        ProposedUpgrade memory newProposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        executeUpgrade(false, "", newProposedUpgrade);
    }

    function test_upgradeWhenThereIsAlreadyPendingUpgrade() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
        bytes32 newCommitment = 0x14f98eb4c8ea8862b2483259641d6dcebf8b2507bf378e62c1af31674bf861d2;
        IExecutor.StoredBatchInfo[] memory newStoredBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        newStoredBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: batch2Info[0].batchNumber,
            batchHash: batch2Info[0].newStateRoot,
            indexRepeatedStorageChanges: batch2Info[0].indexRepeatedStorageChanges,
            numberOfLayer1Txs: batch2Info[0].numberOfLayer1Txs,
            priorityOperationsHash: batch2Info[0].priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: batch2Info[0].timestamp,
            commitment: newCommitment
        });

        executorFacet.proveBatches(storedBatch1InfoChainIdUpgrade[0], newStoredBatch1InfoChainIdUpgrade, proofInput);
        executorFacet.executeBatches(newStoredBatch1InfoChainIdUpgrade);

        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        bytes32 bootloaderHash = bytes32(0);
        bytes32 defaultAccountHash = bytes32(0);
        address verifier = makeAddr("verifier");
        uint256[] memory factoryHash = new uint256[](1);
        factoryHash[0] = uint256(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(0x0000000000000000000000000000000000000000000000000000000000000000);

        VerifierParams memory verifierParams = Utils.makeVerifierParams();
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.nonce = minor + 1;
        upgradeTx.txType = 254;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        upgradeTx.factoryDeps = factoryHash;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: bootloaderHash,
            defaultAccountHash: defaultAccountHash,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        executeUpgrade(false, "", proposedUpgrade);
        newProtocolVersion = packSemver(major, minor + 2, patch);

        ProposedUpgrade memory newProposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: new bytes[](1),
            bootloaderHash: bootloaderHash,
            defaultAccountHash: defaultAccountHash,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        bytes memory revertMsg = abi.encodeWithSelector(
            PreviousUpgradeNotFinalized.selector,
            0x2a372301465b1e0e8dfd0521d620ccfd7119e74599234a3681dea41e0d759d5b
        );
        executeUpgrade(true, revertMsg, newProposedUpgrade);
    }

    function test_nextCommitBatchesContainsNoUpgradeTx() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
        executorFacet.revertBatches(1);

        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        bytes32 bootloaderHash = bytes32(0);
        bytes32 defaultAccountHash = bytes32(0);
        address verifier = makeAddr("verifier");
        uint256[] memory uintEmptyArray;
        bytes[] memory bytesEmptyArray;

        VerifierParams memory verifierParams = Utils.makeVerifierParams();
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.txType = 254;
        upgradeTx.nonce = minor + 1;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        upgradeTx.factoryDeps = uintEmptyArray;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: bytesEmptyArray,
            bootloaderHash: bootloaderHash,
            defaultAccountHash: defaultAccountHash,
            verifier: verifier,
            verifierParams: verifierParams,
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        executeUpgrade(false, "", proposedUpgrade);

        adminFacet.setValidator(msg.sender, true);
        vm.startPrank(0x0000000000000000000000000000000001010101);
        StateTransitionManager(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C).setProtocolVersionDeadline(
            newProtocolVersion,
            999999
        );
        vm.stopPrank();
        vm.startPrank(msg.sender);
        vm.expectRevert(abi.encodeWithSelector(MissingSystemLogs.selector, 16383, 8191));
        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
    }

    function test_additionalUpgradeLogsGoToPriorityOpsHash() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[0] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY),
            0x0000000000000000000000000000000000000000000000000000000000000000
        );
        newL2Logs[1] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY),
            0x0000000000000000000000000000000000000000000000000000000000000000
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            storedBatch1InfoChainIdUpgrade[0].batchHash
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });
        vm.expectRevert(abi.encodeWithSelector(LogAlreadyProcessed.selector, 13));
        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
    }

    function test_commitWhenUpgradeTxHashDoesNotMatch() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogsWithUpgradeTransaction(Utils.randomBytes32(""));
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });
        vm.expectRevert(TxHashMismatch.selector);
        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
    }

    function test_commitSuccessfullyWhenTheUpgradeTxIsPresent() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogsWithUpgradeTransaction(
            0x2a372301465b1e0e8dfd0521d620ccfd7119e74599234a3681dea41e0d759d5b
        );
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        uint256[] memory factoryHash = new uint256[](1);
        factoryHash[0] = uint256(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(0x0000000000000000000000000000000000000000000000000000000000000000);
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.txType = 254;
        upgradeTx.nonce = minor + 1;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        upgradeTx.factoryDeps = factoryHash;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        executeUpgrade(false, "", proposedUpgrade);

        vm.startPrank(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C);
        adminFacet.setValidator(msg.sender, true);
        vm.stopPrank();
        vm.startPrank(0x0000000000000000000000000000000001010101);
        StateTransitionManager(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C).setProtocolVersionDeadline(
            newProtocolVersion,
            999999
        );
        vm.stopPrank();
        vm.startPrank(msg.sender);
        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);

        assertEq(gettersFacet.getL2SystemContractsUpgradeBatchNumber(), 2);
    }

    function test_commitSuccessfullyWhenBatchWasRevertedAndReupgraded() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        bytes[] memory newL2LogsUpgrade = Utils.createSystemLogsWithUpgradeTransaction(
            0x2a372301465b1e0e8dfd0521d620ccfd7119e74599234a3681dea41e0d759d5b
        );
        newL2LogsUpgrade[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2LogsUpgrade[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2Upgrade = Utils.encodePacked(newL2LogsUpgrade);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 newProtocolVersion = packSemver(major, minor + 1, patch);
        uint256[] memory factoryHash = new uint256[](1);
        factoryHash[0] = uint256(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = abi.encode(0x0000000000000000000000000000000000000000000000000000000000000000);
        L2CanonicalTransaction memory upgradeTx = Utils.makeEmptyL2CanonicalTransaction();
        upgradeTx.txType = 254;
        upgradeTx.nonce = minor + 1;
        upgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        upgradeTx.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        upgradeTx.factoryDeps = factoryHash;

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: factoryDeps,
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });

        vm.startPrank(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C);
        adminFacet.setValidator(msg.sender, true);
        vm.stopPrank();

        vm.startPrank(0x0000000000000000000000000000000001010101);
        StateTransitionManager(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C).setProtocolVersionDeadline(
            newProtocolVersion,
            999999
        );
        vm.stopPrank();

        vm.startPrank(msg.sender);
        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
        batch2Info[0].systemLogs = l2Logs2Upgrade;
        executorFacet.revertBatches(1);
        vm.stopPrank();

        executeUpgrade(false, "", proposedUpgrade);

        vm.startPrank(msg.sender);
        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);

        assertEq(gettersFacet.getL2SystemContractsUpgradeBatchNumber(), 2);
    }

    function test_commitSequentialUpgrade() public {
        bytes32 commitment = 0xb6502f3e8460a40fefd7e2758290f8af0ef540348185fb84b258d47d0fa6ba7f;
        IExecutor.StoredBatchInfo[] memory storedBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        storedBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: newCommitBatchInfo.batchNumber,
            batchHash: newCommitBatchInfo.newStateRoot,
            indexRepeatedStorageChanges: newCommitBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: newCommitBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: newCommitBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: newCommitBatchInfo.timestamp,
            commitment: commitment
        });

        bytes[] memory newL2Logs = Utils.createSystemLogs();
        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp + 1, currentTimestamp + 1)
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(storedBatch1InfoChainIdUpgrade[0].batchHash)
        );
        bytes memory l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch2Info = new IExecutor.CommitBatchInfo[](1);
        batch2Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 2,
            timestamp: uint64(storedBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        executorFacet.commitBatches(storedBatch1InfoChainIdUpgrade[0], batch2Info);
        bytes32 newCommitment = 0x14f98eb4c8ea8862b2483259641d6dcebf8b2507bf378e62c1af31674bf861d2;
        IExecutor.StoredBatchInfo[] memory newStoredBatch1InfoChainIdUpgrade = new IExecutor.StoredBatchInfo[](1);
        newStoredBatch1InfoChainIdUpgrade[0] = IExecutor.StoredBatchInfo({
            batchNumber: batch2Info[0].batchNumber,
            batchHash: batch2Info[0].newStateRoot,
            indexRepeatedStorageChanges: batch2Info[0].indexRepeatedStorageChanges,
            numberOfLayer1Txs: batch2Info[0].numberOfLayer1Txs,
            priorityOperationsHash: batch2Info[0].priorityOperationsHash,
            l2LogsTreeRoot: 0x0000000000000000000000000000000000000000000000000000000000000000,
            timestamp: batch2Info[0].timestamp,
            commitment: newCommitment
        });

        executorFacet.proveBatches(storedBatch1InfoChainIdUpgrade[0], newStoredBatch1InfoChainIdUpgrade, proofInput);
        executorFacet.executeBatches(newStoredBatch1InfoChainIdUpgrade);

        uint256 oldProtocolVersion = gettersFacet.getProtocolVersion();
        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: oldProtocolVersion + 1
        });

        executeUpgrade(false, "", proposedUpgrade);

        newL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(
                newStoredBatch1InfoChainIdUpgrade[0].timestamp + 1,
                newStoredBatch1InfoChainIdUpgrade[0].timestamp + 1
            )
        );
        newL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(newStoredBatch1InfoChainIdUpgrade[0].batchHash)
        );
        l2Logs2 = Utils.encodePacked(newL2Logs);

        IExecutor.CommitBatchInfo[] memory batch3Info = new IExecutor.CommitBatchInfo[](1);
        batch3Info[0] = IExecutor.CommitBatchInfo({
            batchNumber: 3,
            timestamp: uint64(newStoredBatch1InfoChainIdUpgrade[0].timestamp + 1),
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32(""),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            bootloaderHeapInitialContentsHash: Utils.randomBytes32(""),
            eventsQueueStateHash: Utils.randomBytes32(""),
            systemLogs: l2Logs2,
            pubdataCommitments: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        vm.startPrank(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C);
        adminFacet.setValidator(msg.sender, true);
        vm.stopPrank();
        vm.startPrank(0x0000000000000000000000000000000001010101);
        StateTransitionManager(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C).setProtocolVersionDeadline(1, 999999);
        vm.stopPrank();
        vm.startPrank(msg.sender);
        executorFacet.commitBatches(newStoredBatch1InfoChainIdUpgrade[0], batch3Info);

        assertEq(gettersFacet.getL2SystemContractsUpgradeBatchNumber(), 0);
    }

    function test_commitCustomUpgrade() public {
        uint256 oldProtocolVersion = gettersFacet.getProtocolVersion();
        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            factoryDeps: new bytes[](1),
            bootloaderHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            defaultAccountHash: 0x0000000000000000000000000000000000000000000000000000000000000000,
            verifier: 0x0000000000000000000000000000000000000000,
            verifierParams: Utils.makeVerifierParams(),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: oldProtocolVersion + 1
        });

        executeCustomUpgrade(false, "", proposedUpgrade);
    }

    function executeCustomUpgrade(
        bool shouldRevert,
        bytes memory revertMsg,
        ProposedUpgrade memory proposedUpgrade
    ) public {
        uint256 oldProtocolVersion = gettersFacet.getProtocolVersion();

        Diamond.DiamondCutData memory newDiamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(genesisUpgradeContract),
            initCalldata: abi.encodeCall(CustomUpgradeTest.upgrade, (proposedUpgrade))
        });

        vm.startPrank(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C);
        if (shouldRevert) {
            vm.expectRevert(revertMsg);
        }
        IAdmin(newChainAddress).executeUpgrade(newDiamondCutData);
    }

    function executeUpgrade(bool shouldRevert, bytes memory revertMsg, ProposedUpgrade memory proposedUpgrade) public {
        uint256 oldProtocolVersion = gettersFacet.getProtocolVersion();

        DefaultUpgrade defaultUpgrade = new DefaultUpgrade();

        Diamond.DiamondCutData memory newDiamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(defaultUpgrade),
            initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
        });

        vm.startPrank(0x9c9f0C42Cb0d4280f51E2BD76687a6c5292aFA6C);
        if (shouldRevert) {
            vm.expectRevert(revertMsg);
        }
        IAdmin(newChainAddress).executeUpgrade(newDiamondCutData);
    }

    function packSemver(uint32 major, uint32 minor, uint32 patch) public returns (uint256) {
        uint256 SEMVER_MINOR_VERSION_MULTIPLIER = 4294967296;
        if (major != 0) {
            revert("Major version must be 0");
        }

        return minor * SEMVER_MINOR_VERSION_MULTIPLIER + patch;
    }

    function getDiamondCutData(address _diamondInit) internal returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(testnetVerifier);

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function createNewChain(Diamond.DiamondCutData memory _diamondCut) internal {
        vm.stopPrank();
        vm.startPrank(bridgehub);

        chainContractAddress.createNewChain({
            _chainId: chainId,
            _baseToken: baseToken,
            _sharedBridge: sharedBridge,
            _admin: newChainAdmin,
            _diamondCut: abi.encode(_diamondCut)
        });
    }

    function gettersSelectors() public pure returns (bytes4[] memory) {
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
        selectors[16] = GettersFacet.getL2SystemContractsUpgradeBatchNumber.selector;
        selectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[19] = GettersFacet.facets.selector;
        selectors[20] = GettersFacet.facetFunctionSelectors.selector;
        selectors[21] = GettersFacet.facetAddresses.selector;
        selectors[22] = GettersFacet.facetAddress.selector;
        selectors[23] = GettersFacet.getSemverProtocolVersion.selector;
        selectors[24] = GettersFacet.getProtocolVersion.selector;
        selectors[25] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[26] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[27] = GettersFacet.getTotalBatchesExecuted.selector;
        selectors[28] = GettersFacet.getL2SystemContractsUpgradeTxHash.selector;
        return selectors;
    }
}
