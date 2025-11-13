// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Utils, DEFAULT_L2_LOGS_TREE_ROOT_HASH, L2_DA_COMMITMENT_SCHEME} from "../Utils/Utils.sol";
import {TESTNET_COMMIT_TIMESTAMP_NOT_OLDER, ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DummyEraBaseTokenBridge} from "contracts/dev-contracts/test/DummyEraBaseTokenBridge.sol";
import {DummyChainTypeManagerForValidatorTimelock as DummyCTM} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {FeeParams, PubdataPricingMode, VerifierParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {TestExecutor} from "contracts/dev-contracts/test/TestExecutor.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IL1DAValidator} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {MessageRootBase} from "contracts/bridgehub/MessageRootBase.sol";

bytes32 constant EMPTY_PREPUBLISHED_COMMITMENT = 0x0000000000000000000000000000000000000000000000000000000000000000;
bytes constant POINT_EVALUATION_PRECOMPILE_RESULT = hex"000000000000000000000000000000000000000000000000000000000000100073eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001";

contract ExecutorTest is Test {
    address internal owner;
    address internal validator;
    address internal randomSigner;
    address internal l1DAValidator;
    AdminFacet internal admin;
    TestExecutor internal executor;
    GettersFacet internal getters;
    MailboxFacet internal mailbox;
    bytes32 internal newCommittedBlockBatchHash;
    bytes32 internal newCommittedBlockCommitment;
    uint256 internal currentTimestamp;
    IExecutor.CommitBatchInfo internal newCommitBatchInfo;
    IExecutor.CommitBatchInfoZKsyncOS internal newCommitBatchInfoZKsyncOS;
    IExecutor.StoredBatchInfo internal newStoredBatchInfo;
    DummyEraBaseTokenBridge internal sharedBridge;
    ValidatorTimelock internal validatorTimelock;
    address internal rollupL1DAValidator;
    L1MessageRoot internal messageRoot;

    uint256 l2ChainId;

    IExecutor.StoredBatchInfo internal genesisStoredBatchInfo;
    uint256[] internal proofInput;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](12);
        uint256 i = 0;
        selectors[i++] = admin.setPendingAdmin.selector;
        selectors[i++] = admin.acceptAdmin.selector;
        selectors[i++] = admin.setValidator.selector;
        selectors[i++] = admin.setPorterAvailability.selector;
        selectors[i++] = admin.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = admin.changeFeeParams.selector;
        selectors[i++] = admin.setTokenMultiplier.selector;
        selectors[i++] = admin.upgradeChainFromVersion.selector;
        selectors[i++] = admin.executeUpgrade.selector;
        selectors[i++] = admin.freezeDiamond.selector;
        selectors[i++] = admin.unfreezeDiamond.selector;
        selectors[i++] = admin.setDAValidatorPair.selector;
        return selectors;
    }

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](8);
        uint256 i = 0;
        selectors[i++] = executor.commitBatchesSharedBridge.selector;
        selectors[i++] = executor.proveBatchesSharedBridge.selector;
        selectors[i++] = executor.executeBatchesSharedBridge.selector;
        selectors[i++] = executor.revertBatchesSharedBridge.selector;
        selectors[i++] = executor.setPriorityTreeStartIndex.selector;
        selectors[i++] = executor.setPriorityTreeHistoricalRoot.selector;
        selectors[i++] = executor.appendPriorityOp.selector;
        selectors[i++] = executor.precommitSharedBridge.selector;
        return selectors;
    }

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](32);
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
        selectors[i++] = getters.getL2BootloaderBytecodeHash.selector;
        selectors[i++] = getters.getL2DefaultAccountBytecodeHash.selector;
        selectors[i++] = getters.getL2EvmEmulatorBytecodeHash.selector;
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
        return selectors;
    }

    function getMailboxSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        uint256 i = 0;
        selectors[i++] = mailbox.proveL2MessageInclusion.selector;
        selectors[i++] = mailbox.proveL2LogInclusion.selector;
        selectors[i++] = mailbox.proveL1ToL2TransactionStatus.selector;
        selectors[i++] = mailbox.finalizeEthWithdrawal.selector;
        selectors[i++] = mailbox.requestL2Transaction.selector;
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
        DummyBridgehub dummyBridgehub = new DummyBridgehub();
        messageRoot = new L1MessageRoot(address(dummyBridgehub));
        dummyBridgehub.setMessageRoot(address(messageRoot));
        sharedBridge = new DummyEraBaseTokenBridge();

        dummyBridgehub.setSharedBridge(address(sharedBridge));

        // FIXME: amend the tests as appending chain batch roots is not allowed on L1.
        // vm.mockCall(
        //     address(messageRoot),
        //     abi.encodeWithSelector(MessageRootBase.addChainBatchRoot.selector, 9, 1, bytes32(0)),
        //     abi.encode()
        // );

        l2ChainId = 9;

        rollupL1DAValidator = Utils.deployL1RollupDAValidatorBytecode();

        admin = new AdminFacet(block.chainid, RollupDAManager(address(0)));
        getters = new GettersFacet();
        executor = new TestExecutor();
        mailbox = new MailboxFacet(l2ChainId, block.chainid);

        DummyCTM chainTypeManager = new DummyCTM(owner, address(0));
        vm.mockCall(
            address(chainTypeManager),
            abi.encodeWithSelector(IChainTypeManager.protocolVersionIsActive.selector),
            abi.encode(bool(true))
        );
        DiamondInit diamondInit = new DiamondInit(isZKsyncOS());
        validatorTimelock = ValidatorTimelock(deployValidatorTimelock(address(dummyBridgehub), owner, 0));

        bytes8 dummyHash = 0x1234567890123456;

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
        EraTestnetVerifier testnetVerifier = new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0)));

        InitializeData memory params = InitializeData({
            // TODO REVIEW
            chainId: l2ChainId,
            bridgehub: address(dummyBridgehub),
            chainTypeManager: address(chainTypeManager),
            protocolVersion: 0,
            admin: owner,
            validatorTimelock: address(validatorTimelock),
            baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS),
            storedBatchZero: keccak256(abi.encode(genesisStoredBatchInfo)),
            verifier: IVerifier(testnetVerifier), // verifier
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: 0,
                recursionLeafLevelVkHash: 0,
                recursionCircuitsSetVksHash: 0
            }),
            l2BootloaderBytecodeHash: dummyHash,
            l2DefaultAccountBytecodeHash: dummyHash,
            l2EvmEmulatorBytecodeHash: dummyHash,
            priorityTxMaxGasLimit: 1000000,
            feeParams: defaultFeeParams()
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

        bytes memory l2Logs = Utils.encodePacked(Utils.createSystemLogs(bytes32(0)));
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
            operatorDAInput: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });
        newCommitBatchInfoZKsyncOS = IExecutor.CommitBatchInfoZKsyncOS({
            batchNumber: 1,
            newStateCommitment: Utils.randomBytes32("newStateCommitment"),
            numberOfLayer1Txs: 0,
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
            operatorDAInput: "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        });

        dummyBridgehub.setZKChain(l2ChainId, address(diamondProxy));

        vm.prank(owner);
        validatorTimelock.addValidatorForChainId(l2ChainId, validator);

        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IL1AssetRouter.bridgehubDepositBaseToken.selector),
            abi.encode(true)
        );
    }

    function isZKsyncOS() internal pure virtual returns (bool) {
        return false;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
