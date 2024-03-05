// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {UtilsFacet} from "../Utils/UtilsFacet.sol";

import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "solpp/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "solpp/state-transition/chain-deps/DiamondProxy.sol";
import {AdminFacet} from "solpp/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "solpp/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "solpp/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "solpp/state-transition/chain-deps/facets/Mailbox.sol";
import {IVerifier, VerifierParams} from "solpp/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {FeeParams, PubdataPricingMode} from "solpp/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {InitializeData, InitializeDataNewChain} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {IExecutor, SystemLogKey} from "solpp/state-transition/chain-interfaces/IExecutor.sol";

bytes32 constant DEFAULT_L2_LOGS_TREE_ROOT_HASH = 0x0000000000000000000000000000000000000000000000000000000000000000;
address constant L2_SYSTEM_CONTEXT_ADDRESS = 0x000000000000000000000000000000000000800B;
address constant L2_BOOTLOADER_ADDRESS = 0x0000000000000000000000000000000000008001;
address constant L2_KNOWN_CODE_STORAGE_ADDRESS = 0x0000000000000000000000000000000000008004;
address constant L2_TO_L1_MESSENGER = 0x0000000000000000000000000000000000008008;
address constant PUBDATA_PUBLISHER_ADDRESS = 0x0000000000000000000000000000000000008011;

library Utils {
    function packBatchTimestampAndBlockTimestamp(
        uint256 batchTimestamp,
        uint256 blockTimestamp
    ) public pure returns (bytes32) {
        uint256 packedNum = (batchTimestamp << 128) | blockTimestamp;
        return bytes32(packedNum);
    }

    function randomBytes32(bytes memory seed) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, seed));
    }

    function constructL2Log(
        bool isService,
        address sender,
        uint256 key,
        bytes32 value
    ) public pure returns (bytes memory) {
        bytes2 servicePrefix = 0x0001;
        if (!isService) {
            servicePrefix = 0x0000;
        }

        return abi.encodePacked(servicePrefix, bytes2(0x0000), sender, key, value);
    }

    function createSystemLogs() public pure returns (bytes[] memory) {
        bytes[] memory logs = new bytes[](9);
        logs[0] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY),
            bytes32("")
        );
        logs[1] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.TOTAL_L2_TO_L1_PUBDATA_KEY),
            0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563
        );
        logs[2] = constructL2Log(true, L2_TO_L1_MESSENGER, uint256(SystemLogKey.STATE_DIFF_HASH_KEY), bytes32(""));
        logs[3] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            bytes32("")
        );
        logs[4] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32("")
        );
        logs[5] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            keccak256("")
        );
        logs[6] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32("")
        );
        logs[7] = constructL2Log(true, PUBDATA_PUBLISHER_ADDRESS, uint256(SystemLogKey.BLOB_ONE_HASH_KEY), bytes32(0));
        logs[8] = constructL2Log(true, PUBDATA_PUBLISHER_ADDRESS, uint256(SystemLogKey.BLOB_TWO_HASH_KEY), bytes32(0));
        return logs;
    }

    function createSystemLogsWithUpgradeTransaction(
        bytes32 _expectedSystemContractUpgradeTxHash
    ) public pure returns (bytes[] memory) {
        bytes[] memory logsWithoutUpgradeTx = createSystemLogs();
        bytes[] memory logs = new bytes[](logsWithoutUpgradeTx.length + 1);
        for (uint256 i = 0; i < logsWithoutUpgradeTx.length; i++) {
            logs[i] = logsWithoutUpgradeTx[i];
        }
        logs[logsWithoutUpgradeTx.length] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY),
            _expectedSystemContractUpgradeTxHash
        );
        return logs;
    }

    function createStoredBatchInfo() public pure returns (IExecutor.StoredBatchInfo memory) {
        return
            IExecutor.StoredBatchInfo({
                batchNumber: 0,
                batchHash: bytes32(""),
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: 0,
                priorityOperationsHash: keccak256(""),
                l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
                timestamp: 0,
                commitment: bytes32("")
            });
    }

    function createCommitBatchInfo() public view returns (IExecutor.CommitBatchInfo memory) {
        return
            IExecutor.CommitBatchInfo({
                batchNumber: 1,
                timestamp: uint64(uint256(randomBytes32("timestamp"))),
                indexRepeatedStorageChanges: 0,
                newStateRoot: randomBytes32("newStateRoot"),
                numberOfLayer1Txs: 0,
                priorityOperationsHash: keccak256(""),
                bootloaderHeapInitialContentsHash: randomBytes32("bootloaderHeapInitialContentsHash"),
                eventsQueueStateHash: randomBytes32("eventsQueueStateHash"),
                systemLogs: abi.encode(randomBytes32("systemLogs")),
                pubdataCommitments: abi.encodePacked(uint256(0))
            });
    }

    function createProofInput() public view returns (IExecutor.ProofInput memory) {
        uint256[] memory recursiveAggregationInput;
        uint256[] memory serializedProof;

        return
            IExecutor.ProofInput({
                recursiveAggregationInput: recursiveAggregationInput,
                serializedProof: serializedProof
            });
    }

    function encodePacked(bytes[] memory data) public pure returns (bytes memory) {
        bytes memory result;
        for (uint256 i = 0; i < data.length; i++) {
            result = abi.encodePacked(result, data[i]);
        }
        return result;
    }

    function getAdminSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AdminFacet.setPendingAdmin.selector;
        selectors[1] = AdminFacet.acceptAdmin.selector;
        selectors[2] = AdminFacet.setValidator.selector;
        selectors[3] = AdminFacet.setPorterAvailability.selector;
        selectors[4] = AdminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[5] = AdminFacet.changeFeeParams.selector;
        selectors[6] = AdminFacet.setTokenMultiplier.selector;
        selectors[7] = AdminFacet.upgradeChainFromVersion.selector;
        selectors[8] = AdminFacet.executeUpgrade.selector;
        selectors[9] = AdminFacet.freezeDiamond.selector;
        selectors[10] = AdminFacet.unfreezeDiamond.selector;
        return selectors;
    }

    function getExecutorSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ExecutorFacet.commitBatches.selector;
        selectors[1] = ExecutorFacet.proveBatches.selector;
        selectors[2] = ExecutorFacet.executeBatches.selector;
        selectors[3] = ExecutorFacet.revertBatches.selector;
        return selectors;
    }

    function getGettersSelectors() public pure returns (bytes4[] memory) {
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
        selectors[16] = GettersFacet.isDiamondStorageFrozen.selector;
        selectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[19] = GettersFacet.facets.selector;
        selectors[20] = GettersFacet.facetFunctionSelectors.selector;
        selectors[21] = GettersFacet.facetAddresses.selector;
        selectors[22] = GettersFacet.facetAddress.selector;
        selectors[23] = GettersFacet.isFunctionFreezable.selector;
        selectors[24] = GettersFacet.isFacetFreezable.selector;
        selectors[25] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[26] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[27] = GettersFacet.getTotalBatchesExecuted.selector;
        selectors[28] = GettersFacet.getL2SystemContractsUpgradeTxHash.selector;
        return selectors;
    }

    function getMailboxSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = MailboxFacet.proveL2MessageInclusion.selector;
        selectors[1] = MailboxFacet.proveL2LogInclusion.selector;
        selectors[2] = MailboxFacet.proveL1ToL2TransactionStatus.selector;
        selectors[3] = MailboxFacet.finalizeEthWithdrawal.selector;
        selectors[4] = MailboxFacet.requestL2Transaction.selector;
        selectors[5] = MailboxFacet.bridgehubRequestL2Transaction.selector;
        selectors[6] = MailboxFacet.l2TransactionBaseCost.selector;
        return selectors;
    }

    function getUtilsFacetSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](36);
        selectors[0] = UtilsFacet.util_setChainId.selector;
        selectors[1] = UtilsFacet.util_getChainId.selector;
        selectors[2] = UtilsFacet.util_setBridgehub.selector;
        selectors[3] = UtilsFacet.util_getBridgehub.selector;
        selectors[4] = UtilsFacet.util_setBaseToken.selector;
        selectors[5] = UtilsFacet.util_getBaseToken.selector;
        selectors[6] = UtilsFacet.util_setBaseTokenBridge.selector;
        selectors[7] = UtilsFacet.util_getBaseTokenBridge.selector;
        selectors[8] = UtilsFacet.util_setVerifier.selector;
        selectors[9] = UtilsFacet.util_getVerifier.selector;
        selectors[10] = UtilsFacet.util_setStoredBatchHashes.selector;
        selectors[11] = UtilsFacet.util_getStoredBatchHashes.selector;
        selectors[12] = UtilsFacet.util_setVerifierParams.selector;
        selectors[13] = UtilsFacet.util_getVerifierParams.selector;
        selectors[14] = UtilsFacet.util_setL2BootloaderBytecodeHash.selector;
        selectors[15] = UtilsFacet.util_getL2BootloaderBytecodeHash.selector;
        selectors[16] = UtilsFacet.util_setL2DefaultAccountBytecodeHash.selector;
        selectors[17] = UtilsFacet.util_getL2DefaultAccountBytecodeHash.selector;
        selectors[18] = UtilsFacet.util_setPendingAdmin.selector;
        selectors[19] = UtilsFacet.util_getPendingAdmin.selector;
        selectors[20] = UtilsFacet.util_setAdmin.selector;
        selectors[21] = UtilsFacet.util_getAdmin.selector;
        selectors[22] = UtilsFacet.util_setValidator.selector;
        selectors[23] = UtilsFacet.util_getValidator.selector;
        selectors[24] = UtilsFacet.util_setZkPorterAvailability.selector;
        selectors[25] = UtilsFacet.util_getZkPorterAvailability.selector;
        selectors[26] = UtilsFacet.util_setStateTransitionManager.selector;
        selectors[27] = UtilsFacet.util_getStateTransitionManager.selector;
        selectors[28] = UtilsFacet.util_setPriorityTxMaxGasLimit.selector;
        selectors[29] = UtilsFacet.util_getPriorityTxMaxGasLimit.selector;
        selectors[30] = UtilsFacet.util_setFeeParams.selector;
        selectors[31] = UtilsFacet.util_getFeeParams.selector;
        selectors[32] = UtilsFacet.util_setProtocolVersion.selector;
        selectors[33] = UtilsFacet.util_getProtocolVersion.selector;
        selectors[34] = UtilsFacet.util_setIsFrozen.selector;
        selectors[35] = UtilsFacet.util_getIsFrozen.selector;
        return selectors;
    }

    // function initial_deployment() public returns (address[] memory) {
    //     GettersFacet gettersFacet = new GettersFacet();
    //     MailboxFacet mailboxFacet = new MailboxFacet();
    //     // allowList = new AllowList(owner);
    //     DiamondInit diamondInit = new DiamondInit();

    //     bytes8 dummyHash = 0x1234567890123456;
    //     address dummyAddress = makeAddr("dummyAddress");
    //     bytes memory diamondInitData = abi.encodeWithSelector(
    //         diamondInit.initialize.selector,
    //         dummyAddress,
    //         owner,
    //         owner,
    //         0,
    //         0,
    //         0,
    //         allowList,
    //         VerifierParams({recursionNodeLevelVkHash: 0, recursionLeafLevelVkHash: 0, recursionCircuitsSetVksHash: 0}),
    //         false,
    //         dummyHash,
    //         dummyHash,
    //         10000000
    //     );

    //     Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
    //     facetCuts[0] = Diamond.FacetCut({
    //         facet: address(gettersFacet),
    //         action: Diamond.Action.Add,
    //         isFreezable: false,
    //         selectors: Utils.getGettersSelectors()
    //     });
    //     facetCuts[1] = Diamond.FacetCut({
    //         facet: address(mailboxFacet),
    //         action: Diamond.Action.Add,
    //         isFreezable: true,
    //         selectors: Utils.getMailboxSelectors()
    //     });

    //     Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
    //         facetCuts: facetCuts,
    //         initAddress: address(diamondInit),
    //         initCalldata: diamondInitData
    //     });

    //     uint256 chainId = block.chainid;
    //     DiamondProxy diamondProxy = new DiamondProxy(chainId, diamondCutData);

    //     vm.prank(owner);
    //     allowList.setAccessMode(address(diamondProxy), IAllowList.AccessMode.Public);
    // }

    function makeVerifier() public pure returns (IVerifier) {
        return IVerifier(address(0xdeadbeef));
    }

    function makeVerifierParams() public pure returns (VerifierParams memory) {
        return
            VerifierParams({recursionNodeLevelVkHash: 0, recursionLeafLevelVkHash: 0, recursionCircuitsSetVksHash: 0});
    }

    function makeFeeParams() public pure returns (FeeParams memory) {
        return
            FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            });
    }

    function makeInitializeData() public pure returns (InitializeData memory) {
        return
            InitializeData({
                chainId: 1,
                bridgehub: address(0x876543567890),
                stateTransitionManager: address(0x1234567890876543567890),
                protocolVersion: 0,
                admin: address(0x32149872498357874258787),
                validatorTimelock: address(0x85430237648403822345345),
                baseToken: address(0x923645439232223445),
                baseTokenBridge: address(0x23746765237749923040872834),
                storedBatchZero: bytes32(0),
                verifier: makeVerifier(),
                verifierParams: makeVerifierParams(),
                l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                priorityTxMaxGasLimit: 500000,
                feeParams: makeFeeParams(),
                blobVersionedHashRetriever: address(0x23746765237749923040872834)
            });
    }

    function makeInitializeDataForNewChain() public pure returns (InitializeDataNewChain memory) {
        return
            InitializeDataNewChain({
                verifier: makeVerifier(),
                verifierParams: makeVerifierParams(),
                l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                priorityTxMaxGasLimit: 80000000,
                feeParams: makeFeeParams(),
                blobVersionedHashRetriever: address(0x23746765237749923040872834)
            });
    }

    function makeDiamondProxy(Diamond.FacetCut[] memory facetCuts) public returns (address) {
        DiamondInit diamondInit = new DiamondInit();
        bytes memory diamondInitData = abi.encodeWithSelector(diamondInit.initialize.selector, makeInitializeData());

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitData
        });

        uint256 chainId = block.chainid;
        DiamondProxy diamondProxy = new DiamondProxy(chainId, diamondCutData);
        return address(diamondProxy);
    }

    function createBatchCommitment(
        IExecutor.CommitBatchInfo calldata _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) public pure returns (bytes32) {
        bytes32 passThroughDataHash = keccak256(_batchPassThroughData(_newBatchData));
        bytes32 metadataHash = keccak256(_batchMetaParameters());
        bytes32 auxiliaryOutputHash = keccak256(
            _batchAuxiliaryOutput(_newBatchData, _stateDiffHash, _blobCommitments, _blobHashes)
        );

        return keccak256(abi.encode(passThroughDataHash, metadataHash, auxiliaryOutputHash));
    }

    function _batchPassThroughData(IExecutor.CommitBatchInfo calldata _batch) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                _batch.indexRepeatedStorageChanges,
                _batch.newStateRoot,
                uint64(0), // index repeated storage changes in zkPorter
                bytes32(0) // zkPorter batch hash
            );
    }

    function _batchMetaParameters() internal pure returns (bytes memory) {
        // Used in __Executor_Shared.t.sol
        bytes8 dummyHash = 0x1234567890123456;
        return abi.encodePacked(false, bytes32(dummyHash), bytes32(dummyHash));
    }

    function _batchAuxiliaryOutput(
        IExecutor.CommitBatchInfo calldata _batch,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal pure returns (bytes memory) {
        bytes32 l2ToL1LogsHash = keccak256(_batch.systemLogs);

        return
            abi.encode(
                l2ToL1LogsHash,
                _stateDiffHash,
                _batch.bootloaderHeapInitialContentsHash,
                _batch.eventsQueueStateHash,
                // for each blob we have:
                // linear hash (hash of preimage from system logs) and
                // output hash of blob commitments: keccak(versioned hash || opening point || evaluation value)
                // These values will all be bytes32(0) when we submit pubdata via calldata instead of blobs.
                // If we only utilize a single blob, _blobHash[1] and _blobCommitments[1] will be bytes32(0)
                _blobHashes[0],
                _blobCommitments[0],
                _blobHashes[1],
                _blobCommitments[1]
            );
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
