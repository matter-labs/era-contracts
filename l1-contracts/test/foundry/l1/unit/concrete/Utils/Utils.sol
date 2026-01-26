// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UtilsFacet} from "../Utils/UtilsFacet.sol";

import "forge-std/console.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";

import {
    FeeParams,
    IVerifier,
    PubdataPricingMode,
    VerifierParams
} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InitializeData, InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {InteropRoot, L2CanonicalTransaction, L2Log} from "contracts/common/Messaging.sol";

import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {InvalidBlobCommitmentsLength, InvalidBlobHashesLength} from "test/foundry/L1TestsErrors.sol";
import {Utils as DeployUtils} from "deploy-scripts/utils/Utils.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {ContractsBytecodesLib} from "deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";

bytes32 constant DEFAULT_L2_LOGS_TREE_ROOT_HASH = 0x0000000000000000000000000000000000000000000000000000000000000000;
address constant L2_SYSTEM_CONTEXT_ADDRESS = 0x000000000000000000000000000000000000800B;
address constant L2_BOOTLOADER_ADDRESS = 0x0000000000000000000000000000000000008001;
address constant L2_KNOWN_CODE_STORAGE_ADDRESS = 0x0000000000000000000000000000000000008004;
address constant L2_TO_L1_MESSENGER = 0x0000000000000000000000000000000000008008;
// constant in tests, but can be arbitrary address in real environments
L2DACommitmentScheme constant L2_DA_COMMITMENT_SCHEME = L2DACommitmentScheme.PUBDATA_KECCAK256;

uint256 constant MAX_NUMBER_OF_BLOBS = 6;
uint256 constant TOTAL_BLOBS_IN_COMMITMENT = 16;

uint256 constant EVENT_INDEX = 0;

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

        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(servicePrefix, bytes2(0x0000), sender, key, value);
    }

    function createSystemLogs(bytes32 _outputHash) public returns (bytes[] memory) {
        bytes[] memory logs = new bytes[](10);
        logs[0] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY),
            bytes32("")
        );
        logs[1] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            bytes32("")
        );
        logs[2] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            keccak256("")
        );
        logs[3] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
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
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY),
            _outputHash
        );
        logs[6] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.USED_L2_DA_VALIDATOR_ADDRESS_KEY),
            bytes32(uint256(L2_DA_COMMITMENT_SCHEME))
        );
        logs[7] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.MESSAGE_ROOT_ROLLING_HASH_KEY),
            bytes32(uint256(uint160(0)))
        );
        logs[8] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.L2_TXS_STATUS_ROLLING_HASH_KEY),
            bytes32("")
        );
        logs[9] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.SETTLEMENT_LAYER_CHAIN_ID_KEY),
            bytes32(uint256(uint160(block.chainid)))
        );

        return logs;
    }

    function createSystemLogsWithNoneDAValidator() public returns (bytes[] memory) {
        bytes[] memory systemLogs = createSystemLogs(bytes32(0));
        systemLogs[uint256(SystemLogKey.USED_L2_DA_VALIDATOR_ADDRESS_KEY)] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.USED_L2_DA_VALIDATOR_ADDRESS_KEY),
            bytes32(uint256(L2DACommitmentScheme.NONE))
        );

        return systemLogs;
    }

    function createSystemLogsWithUpgradeTransaction(
        bytes32 _expectedSystemContractUpgradeTxHash
    ) public returns (bytes[] memory) {
        bytes[] memory logsWithoutUpgradeTx = createSystemLogs(bytes32(0));
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

    function createSystemLogsWithUpgradeTransactionForCTM(
        bytes32 _expectedSystemContractUpgradeTxHash,
        bytes32 _outputHash
    ) public returns (bytes[] memory) {
        bytes[] memory logsWithoutUpgradeTx = createSystemLogs(_outputHash);
        bytes[] memory logs = new bytes[](logsWithoutUpgradeTx.length + 1);
        for (uint256 i = 0; i < logsWithoutUpgradeTx.length; i++) {
            logs[i] = logsWithoutUpgradeTx[i];
        }
        logs[uint256(SystemLogKey.PREV_BATCH_HASH_KEY)] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(uint256(0x01))
        );
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
                dependencyRootsRollingHash: bytes32(0),
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
                operatorDAInput: abi.encodePacked(uint256(0))
            });
    }

    function encodePacked(bytes[] memory data) public pure returns (bytes memory) {
        bytes memory result;
        for (uint256 i = 0; i < data.length; i++) {
            result = abi.encodePacked(result, data[i]);
        }
        return result;
    }

    function encodeCommitBatchesData(
        IExecutor.StoredBatchInfo memory _lastCommittedBatchData,
        IExecutor.CommitBatchInfo[] memory _newBatchesData
    ) internal pure returns (uint256, uint256, bytes memory) {
        return (
            _newBatchesData[0].batchNumber,
            _newBatchesData[_newBatchesData.length - 1].batchNumber,
            bytes.concat(
                bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
                abi.encode(_lastCommittedBatchData, _newBatchesData)
            )
        );
    }

    function encodeCommitBatchesDataZKsyncOS(
        IExecutor.StoredBatchInfo memory _lastCommittedBatchData,
        IExecutor.CommitBatchInfoZKsyncOS[] memory _newBatchesData
    ) internal pure returns (uint256, uint256, bytes memory) {
        return (
            _newBatchesData[0].batchNumber,
            _newBatchesData[_newBatchesData.length - 1].batchNumber,
            bytes.concat(
                bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT_ZKSYNC_OS),
                abi.encode(_lastCommittedBatchData, _newBatchesData)
            )
        );
    }

    function encodeProveBatchesData(
        IExecutor.StoredBatchInfo memory _prevBatch,
        IExecutor.StoredBatchInfo[] memory _committedBatches,
        uint256[] memory _proof
    ) internal pure returns (uint256, uint256, bytes memory) {
        return (
            _committedBatches[0].batchNumber,
            _committedBatches[_committedBatches.length - 1].batchNumber,
            bytes.concat(
                bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
                abi.encode(_prevBatch, _committedBatches, _proof)
            )
        );
    }

    function encodeExecuteBatchesData(
        IExecutor.StoredBatchInfo[] memory _batchesData,
        PriorityOpsBatchInfo[] memory _priorityOpsData
    ) internal pure returns (uint256, uint256, bytes memory) {
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](_batchesData.length);
        L2Log[] memory l2Logs = new L2Log[](_batchesData.length);
        bytes[] memory messages = new bytes[](_batchesData.length);
        bytes32[] memory messageRoots = new bytes32[](_batchesData.length);

        return (
            _batchesData[0].batchNumber,
            _batchesData[_batchesData.length - 1].batchNumber,
            bytes.concat(
                bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
                abi.encode(_batchesData, _priorityOpsData, dependencyRoots, l2Logs, messages, messageRoots)
            )
        );
    }

    function encodeExecuteBatchesDataZeroLogs(
        IExecutor.StoredBatchInfo[] memory _batchesData,
        PriorityOpsBatchInfo[] memory _priorityOpsData
    ) internal pure returns (uint256, uint256, bytes memory) {
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](_batchesData.length);
        L2Log[] memory l2Logs = new L2Log[](0);
        bytes[] memory messages = new bytes[](0);
        bytes32[] memory messageRoots = new bytes32[](0);

        return (
            _batchesData[0].batchNumber,
            _batchesData[_batchesData.length - 1].batchNumber,
            bytes.concat(
                bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
                abi.encode(_batchesData, _priorityOpsData, dependencyRoots, l2Logs, messages, messageRoots)
            )
        );
    }

    function getAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](14);
        uint256 i = 0;
        selectors[i++] = AdminFacet.setPendingAdmin.selector;
        selectors[i++] = AdminFacet.acceptAdmin.selector;
        selectors[i++] = AdminFacet.setValidator.selector;
        selectors[i++] = AdminFacet.setPorterAvailability.selector;
        selectors[i++] = AdminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = AdminFacet.changeFeeParams.selector;
        selectors[i++] = AdminFacet.setTokenMultiplier.selector;
        selectors[i++] = AdminFacet.upgradeChainFromVersion.selector;
        selectors[i++] = AdminFacet.executeUpgrade.selector;
        selectors[i++] = AdminFacet.freezeDiamond.selector;
        selectors[i++] = AdminFacet.unfreezeDiamond.selector;
        selectors[i++] = AdminFacet.genesisUpgrade.selector;
        selectors[i++] = AdminFacet.setDAValidatorPair.selector;
        selectors[i++] = AdminFacet.pauseDepositsBeforeInitiatingMigration.selector;
        return selectors;
    }

    function getExecutorSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        uint256 i = 0;
        selectors[i++] = ExecutorFacet.commitBatchesSharedBridge.selector;
        selectors[i++] = ExecutorFacet.proveBatchesSharedBridge.selector;
        selectors[i++] = ExecutorFacet.executeBatchesSharedBridge.selector;
        selectors[i++] = ExecutorFacet.revertBatchesSharedBridge.selector;
        return selectors;
    }

    function getGettersSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](34);
        uint256 i = 0;
        selectors[i++] = GettersFacet.getVerifier.selector;
        selectors[i++] = GettersFacet.getAdmin.selector;
        selectors[i++] = GettersFacet.getPendingAdmin.selector;
        selectors[i++] = GettersFacet.getTotalBlocksCommitted.selector;
        selectors[i++] = GettersFacet.getTotalBlocksVerified.selector;
        selectors[i++] = GettersFacet.getTotalBlocksExecuted.selector;
        selectors[i++] = GettersFacet.getTotalPriorityTxs.selector;
        selectors[i++] = GettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[i++] = GettersFacet.getPriorityQueueSize.selector;
        selectors[i++] = GettersFacet.getL2SystemContractsUpgradeTxHash.selector;
        selectors[i++] = GettersFacet.isValidator.selector;
        selectors[i++] = GettersFacet.l2LogsRootHash.selector;
        selectors[i++] = GettersFacet.storedBatchHash.selector;
        selectors[i++] = GettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[i++] = GettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[i++] = GettersFacet.getL2EvmEmulatorBytecodeHash.selector;
        selectors[i++] = GettersFacet.getVerifierParams.selector;
        selectors[i++] = GettersFacet.isDiamondStorageFrozen.selector;
        selectors[i++] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[i++] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[i++] = GettersFacet.facets.selector;
        selectors[i++] = GettersFacet.facetFunctionSelectors.selector;
        selectors[i++] = GettersFacet.facetAddresses.selector;
        selectors[i++] = GettersFacet.facetAddress.selector;
        selectors[i++] = GettersFacet.isFunctionFreezable.selector;
        selectors[i++] = GettersFacet.isFacetFreezable.selector;
        selectors[i++] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[i++] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[i++] = GettersFacet.getTotalBatchesExecuted.selector;
        selectors[i++] = GettersFacet.getProtocolVersion.selector;
        selectors[i++] = GettersFacet.getPriorityTreeRoot.selector;
        selectors[i++] = GettersFacet.getChainId.selector;
        selectors[i++] = GettersFacet.baseTokenGasPriceMultiplierDenominator.selector;
        selectors[i++] = GettersFacet.baseTokenGasPriceMultiplierNominator.selector;

        return selectors;
    }

    function getMailboxSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](9);
        uint256 i = 0;
        selectors[i++] = MailboxFacet.proveL2MessageInclusion.selector;
        selectors[i++] = MailboxFacet.proveL2LogInclusion.selector;
        selectors[i++] = MailboxFacet.proveL1ToL2TransactionStatus.selector;
        selectors[i++] = MailboxFacet.finalizeEthWithdrawal.selector;
        selectors[i++] = MailboxFacet.requestL2Transaction.selector;
        selectors[i++] = MailboxFacet.bridgehubRequestL2Transaction.selector;
        selectors[i++] = MailboxFacet.l2TransactionBaseCost.selector;
        selectors[i++] = MailboxFacet.proveL2LeafInclusion.selector;
        selectors[i++] = MailboxFacet.requestL2ServiceTransaction.selector;
        return selectors;
    }

    function getUtilsFacetSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](59);

        uint256 i = 0;
        selectors[i++] = UtilsFacet.util_setChainId.selector;
        selectors[i++] = UtilsFacet.util_getChainId.selector;
        selectors[i++] = UtilsFacet.util_setBridgehub.selector;
        selectors[i++] = UtilsFacet.util_getBridgehub.selector;
        selectors[i++] = UtilsFacet.util_setBaseToken.selector;
        selectors[i++] = UtilsFacet.util_getBaseTokenAssetId.selector;
        selectors[i++] = UtilsFacet.util_setVerifier.selector;
        selectors[i++] = UtilsFacet.util_getVerifier.selector;
        selectors[i++] = UtilsFacet.util_setStoredBatchHashes.selector;
        selectors[i++] = UtilsFacet.util_getStoredBatchHashes.selector;
        selectors[i++] = UtilsFacet.util_setVerifierParams.selector;
        selectors[i++] = UtilsFacet.util_getVerifierParams.selector;
        selectors[i++] = UtilsFacet.util_setL2BootloaderBytecodeHash.selector;
        selectors[i++] = UtilsFacet.util_getL2BootloaderBytecodeHash.selector;
        selectors[i++] = UtilsFacet.util_setL2DefaultAccountBytecodeHash.selector;
        selectors[i++] = UtilsFacet.util_getL2DefaultAccountBytecodeHash.selector;
        selectors[i++] = UtilsFacet.util_getL2EvmEmulatorBytecodeHash.selector;
        selectors[i++] = UtilsFacet.util_setL2EvmEmulatorBytecodeHash.selector;
        selectors[i++] = UtilsFacet.util_setPendingAdmin.selector;
        selectors[i++] = UtilsFacet.util_getPendingAdmin.selector;
        selectors[i++] = UtilsFacet.util_setAdmin.selector;
        selectors[i++] = UtilsFacet.util_getAdmin.selector;
        selectors[i++] = UtilsFacet.util_setValidator.selector;
        selectors[i++] = UtilsFacet.util_getValidator.selector;
        selectors[i++] = UtilsFacet.util_setZkPorterAvailability.selector;
        selectors[i++] = UtilsFacet.util_getZkPorterAvailability.selector;
        selectors[i++] = UtilsFacet.util_setChainTypeManager.selector;
        selectors[i++] = UtilsFacet.util_getChainTypeManager.selector;
        selectors[i++] = UtilsFacet.util_setPriorityTxMaxGasLimit.selector;
        selectors[i++] = UtilsFacet.util_getPriorityTxMaxGasLimit.selector;
        selectors[i++] = UtilsFacet.util_setFeeParams.selector;
        selectors[i++] = UtilsFacet.util_getFeeParams.selector;
        selectors[i++] = UtilsFacet.util_setProtocolVersion.selector;
        selectors[i++] = UtilsFacet.util_getProtocolVersion.selector;
        selectors[i++] = UtilsFacet.util_setIsFrozen.selector;
        selectors[i++] = UtilsFacet.util_getIsFrozen.selector;
        selectors[i++] = UtilsFacet.util_setTransactionFilterer.selector;
        selectors[i++] = UtilsFacet.util_setBaseTokenGasPriceMultiplierDenominator.selector;
        selectors[i++] = UtilsFacet.util_setTotalBatchesExecuted.selector;
        selectors[i++] = UtilsFacet.util_setL2LogsRootHash.selector;
        selectors[i++] = UtilsFacet.util_setBaseTokenGasPriceMultiplierNominator.selector;
        selectors[i++] = UtilsFacet.util_setTotalBatchesCommitted.selector;
        selectors[i++] = UtilsFacet.util_getBaseTokenGasPriceMultiplierDenominator.selector;
        selectors[i++] = UtilsFacet.util_getBaseTokenGasPriceMultiplierNominator.selector;
        selectors[i++] = UtilsFacet.util_getL2DACommimentScheme.selector;
        selectors[i++] = UtilsFacet.util_setSettlementLayer.selector;
        selectors[i++] = UtilsFacet.util_getSettlementLayer.selector;
        selectors[i++] = UtilsFacet.util_setPausedDepositsTimestamp.selector;
        selectors[i++] = UtilsFacet.util_getPausedDepositsTimestamp.selector;
        selectors[i++] = UtilsFacet.util_setAssetTracker.selector;
        selectors[i++] = UtilsFacet.util_setNativeTokenVault.selector;
        selectors[i++] = UtilsFacet.util_setTotalBatchesVerified.selector;
        selectors[i++] = UtilsFacet.util_getTotalBatchesVerified.selector;
        selectors[i++] = UtilsFacet.util_getTotalBatchesExecuted.selector;
        selectors[i++] = UtilsFacet.util_getTotalBatchesCommitted.selector;
        selectors[i++] = UtilsFacet.util_setL2SystemContractsUpgradeBatchNumber.selector;
        selectors[i++] = UtilsFacet.util_getL2SystemContractsUpgradeBatchNumber.selector;
        selectors[i++] = UtilsFacet.util_setL2SystemContractsUpgradeTxHash.selector;
        selectors[i++] = UtilsFacet.util_getL2SystemContractsUpgradeTxHash.selector;

        return selectors;
    }

    function makeVerifier(address testnetVerifier) public pure returns (IVerifier) {
        return IVerifier(testnetVerifier);
    }

    function makeInitializeData(address testnetVerifier, address bridgehub) public returns (InitializeData memory) {
        return
            InitializeData({
                chainId: 1,
                bridgehub: bridgehub,
                chainTypeManager: address(0x1234567890876543567890),
                interopCenter: address(0x1234567890876543567890),
                protocolVersion: 0,
                admin: address(0x32149872498357874258787),
                validatorTimelock: address(0x85430237648403822345345),
                baseTokenAssetId: bytes32(uint256(0x923645439232223445)),
                storedBatchZero: bytes32(0),
                verifier: makeVerifier(testnetVerifier),
                l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                l2EvmEmulatorBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000
            });
    }

    function makeInitializeDataForNewChain(
        address testnetVerifier
    ) public pure returns (InitializeDataNewChain memory) {
        return
            InitializeDataNewChain({
                verifier: makeVerifier(testnetVerifier),
                l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
                l2EvmEmulatorBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000
            });
    }

    function makeDiamondProxy(
        Diamond.FacetCut[] memory facetCuts,
        address testnetVerifier,
        address bridgehub
    ) public returns (address) {
        DiamondInit diamondInit = new DiamondInit(false);
        bytes memory diamondInitData = abi.encodeWithSelector(
            diamondInit.initialize.selector,
            makeInitializeData(testnetVerifier, bridgehub)
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitData
        });

        uint256 chainId = block.chainid;
        DiamondProxy diamondProxy = new DiamondProxy(chainId, diamondCutData);
        return address(diamondProxy);
    }

    function makeEmptyL2CanonicalTransaction() public returns (L2CanonicalTransaction memory) {
        uint256[4] memory reserved;
        uint256[] memory factoryDeps = new uint256[](1);
        return
            L2CanonicalTransaction({
                txType: 0,
                from: 0,
                to: 0,
                gasLimit: 0,
                gasPerPubdataByteLimit: 0,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                paymaster: 0,
                nonce: 0,
                value: 0,
                reserved: reserved,
                data: "",
                signature: "",
                factoryDeps: factoryDeps,
                paymasterInput: "",
                reservedDynamic: ""
            });
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
            // solhint-disable-next-line func-named-parameters
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
        return abi.encodePacked(false, bytes32(dummyHash), bytes32(dummyHash), bytes32(dummyHash));
    }

    function _batchAuxiliaryOutput(
        IExecutor.CommitBatchInfo calldata _batch,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal pure returns (bytes memory) {
        bytes32 l2ToL1LogsHash = keccak256(_batch.systemLogs);

        return
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(
                l2ToL1LogsHash,
                _stateDiffHash,
                _batch.bootloaderHeapInitialContentsHash,
                _batch.eventsQueueStateHash,
                _encodeBlobAuxiliaryOutput(_blobCommitments, _blobHashes)
            );
    }

    /// @dev Encodes the commitment to blobs to be used in the auxiliary output of the batch commitment
    /// @param _blobCommitments - the commitments to the blobs
    /// @param _blobHashes - the hashes of the blobs
    /// @param blobAuxOutputWords - The circuit commitment to the blobs split into 32-byte words
    function _encodeBlobAuxiliaryOutput(
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal pure returns (bytes32[] memory blobAuxOutputWords) {
        // These invariants should be checked by the caller of this function, but we double check
        // just in case.
        if (_blobCommitments.length != TOTAL_BLOBS_IN_COMMITMENT) {
            revert InvalidBlobCommitmentsLength();
        }
        if (_blobHashes.length != TOTAL_BLOBS_IN_COMMITMENT) {
            revert InvalidBlobHashesLength();
        }

        // for each blob we have:
        // linear hash (hash of preimage from system logs) and
        // output hash of blob commitments: keccak(versioned hash || opening point || evaluation value)
        // These values will all be bytes32(0) when we submit pubdata via calldata instead of blobs.
        //
        // For now, only up to 2 blobs are supported by the contract, while 16 are required by the circuits.
        // All the unfilled blobs will have their commitment as 0, including the case when we use only 1 blob.

        blobAuxOutputWords = new bytes32[](2 * TOTAL_BLOBS_IN_COMMITMENT);

        for (uint256 i = 0; i < TOTAL_BLOBS_IN_COMMITMENT; i++) {
            blobAuxOutputWords[i * 2] = _blobHashes[i];
            blobAuxOutputWords[i * 2 + 1] = _blobCommitments[i];
        }
    }

    function constructRollupL2DAValidatorOutputHash(
        bytes32 _stateDiffHash,
        bytes32 _totalPubdataHash,
        uint8 _blobsAmount,
        bytes32[] memory _blobHashes
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_stateDiffHash, _totalPubdataHash, _blobsAmount, _blobHashes));
    }

    function getDefaultBlobCommitment() public pure returns (bytes memory) {
        bytes16 blobOpeningPoint = 0x7142c5851421a2dc03dde0aabdb0ffdb;
        bytes32 blobClaimedValue = 0x1e5eea3bbb85517461c1d1c7b84c7c2cec050662a5e81a71d5d7e2766eaff2f0;
        bytes
            memory commitment = hex"ad5a32c9486ad7ab553916b36b742ed89daffd4538d95f4fc8a6c5c07d11f4102e34b3c579d9b4eb6c295a78e484d3bf";
        bytes
            memory blobProof = hex"b7565b1cf204d9f35cec98a582b8a15a1adff6d21f3a3a6eb6af5a91f0a385c069b34feb70bea141038dc7faca5ed364";

        return abi.encodePacked(blobOpeningPoint, blobClaimedValue, commitment, blobProof);
    }

    function defaultPointEvaluationPrecompileInput(bytes32 _versionedHash) public view returns (bytes memory) {
        return
            abi.encodePacked(
                _versionedHash,
                bytes32(uint256(uint128(0x7142c5851421a2dc03dde0aabdb0ffdb))), // opening point
                abi.encodePacked(
                    bytes32(0x1e5eea3bbb85517461c1d1c7b84c7c2cec050662a5e81a71d5d7e2766eaff2f0), // claimed value
                    hex"ad5a32c9486ad7ab553916b36b742ed89daffd4538d95f4fc8a6c5c07d11f4102e34b3c579d9b4eb6c295a78e484d3bf", // commitment
                    hex"b7565b1cf204d9f35cec98a582b8a15a1adff6d21f3a3a6eb6af5a91f0a385c069b34feb70bea141038dc7faca5ed364" // proof
                )
            );
    }

    function emptyData() internal pure returns (PriorityOpsBatchInfo[] calldata _empty) {
        assembly {
            _empty.offset := 0
            _empty.length := 0
        }
    }

    function generatePriorityOps(uint256 len) internal pure returns (PriorityOpsBatchInfo[] memory _ops) {
        return generatePriorityOps(len, 2);
    }

    function generatePriorityOps(
        uint256 len,
        uint256 priorityOpsLength
    ) internal pure returns (PriorityOpsBatchInfo[] memory _ops) {
        _ops = new PriorityOpsBatchInfo[](len);
        bytes32[] memory empty;
        bytes32[] memory hashes = new bytes32[](priorityOpsLength);
        for (uint256 i = 0; i < priorityOpsLength; ++i) {
            hashes[i] = keccak256(abi.encodePacked("hash", i));
        }
        bytes32[] memory leftPath = new bytes32[](2);
        leftPath[0] = keccak256("left1");
        leftPath[1] = keccak256("left2");
        bytes32[] memory rightPath = new bytes32[](2);
        rightPath[0] = keccak256("right1");
        rightPath[1] = keccak256("right2");
        PriorityOpsBatchInfo memory info = PriorityOpsBatchInfo({
            leftPath: leftPath,
            rightPath: rightPath,
            itemHashes: hashes
        });

        for (uint256 i = 0; i < len; ++i) {
            _ops[i] = info;
        }
    }

    function deployL1RollupDAValidatorBytecode() internal returns (address) {
        bytes memory bytecode = ContractsBytecodesLib.getCreationCodeEVM("RollupL1DAValidator");

        return deployViaCreate(bytecode);
    }

    function deployEIP7702Checker() internal returns (address) {
        bytes memory bytecode = ContractsBytecodesLib.getCreationCodeEVM("EIP7702Checker");

        return deployViaCreate(bytecode);
    }

    function deployBlobsL1DAValidatorZKsyncOSBytecode() internal returns (address) {
        bytes memory bytecode = ContractsBytecodesLib.getCreationCodeEVM("BlobsL1DAValidatorZKsyncOS");

        return deployViaCreate(bytecode);
    }

    /**
     * @dev Deploys contract using CREATE.
     */
    function deployViaCreate(bytes memory _bytecode) internal returns (address addr) {
        if (_bytecode.length == 0) {
            revert("Bytecode is not set");
        }

        assembly {
            // Allocate memory for the bytecode
            let size := mload(_bytecode) // Load the size of the bytecode
            let ptr := add(_bytecode, 0x20) // Skip the length prefix (32 bytes)

            // Create the contract
            addr := create(0, ptr, size)
        }

        require(addr != address(0), "Deployment failed");
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
