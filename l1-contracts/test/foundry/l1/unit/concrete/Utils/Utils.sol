// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UtilsFacet} from "../Utils/UtilsFacet.sol";

import "forge-std/console.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";

import {
    FeeParams,
    IVerifier,
    PubdataPricingMode,
    VerifierParams
} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {
    IExecutor,
    MAX_NUMBER_OF_BLOBS,
    TOTAL_BLOBS_IN_COMMITMENT
} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
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
// Owner of the RollupDAManager in tests
address constant TEST_ROLLUP_DA_MANAGER_OWNER = address(0x1234567890DEADBEEF);

uint256 constant EVENT_INDEX = 0;

library Utils {
    function randomBytes32(bytes memory seed) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, seed));
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

    function createCommitBatchInfoZKsyncOS() public view returns (CommitBatchInfoZKsyncOS memory) {
        return
            CommitBatchInfoZKsyncOS({
                batchNumber: 1,
                newStateCommitment: randomBytes32("newStateCommitment"),
                numberOfLayer1Txs: 0,
                numberOfLayer2Txs: 0,
                priorityOperationsHash: keccak256(""),
                dependencyRootsRollingHash: keccak256(""),
                l2LogsTreeRoot: bytes32(""),
                daCommitmentScheme: L2_DA_COMMITMENT_SCHEME,
                daCommitment: bytes32(""),
                firstBlockTimestamp: uint64(uint256(randomBytes32("timestamp")) >> 200),
                firstBlockNumber: 1,
                lastBlockTimestamp: uint64(uint256(randomBytes32("timestamp")) >> 200),
                lastBlockNumber: 2,
                chainId: 9,
                operatorDAInput: abi.encodePacked(uint256(0)),
                slChainId: block.chainid
            });
    }

    function encodePacked(bytes[] memory data) public pure returns (bytes memory) {
        bytes memory result;
        for (uint256 i = 0; i < data.length; i++) {
            result = abi.encodePacked(result, data[i]);
        }
        return result;
    }

    function encodeCommitBatchesDataZKsyncOS(
        IExecutor.StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfoZKsyncOS[] memory _newBatchesData
    ) internal pure returns (uint256, uint256, bytes memory) {
        return (
            _newBatchesData[0].batchNumber,
            _newBatchesData[_newBatchesData.length - 1].batchNumber,
            bytes.concat(
                bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT),
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
        uint256 len = _batchesData.length;
        bytes memory encoded = abi.encode(
            BatchDecoder.DecodedExecuteData({
                batchesData: _batchesData,
                priorityOpsData: _priorityOpsData,
                dependencyRoots: new InteropRoot[][](len)
            })
        );
        return (
            _batchesData[0].batchNumber,
            _batchesData[len - 1].batchNumber,
            bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE), encoded)
        );
    }

    function getAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](18);
        uint256 i = 0;
        selectors[i++] = AdminFacet.setPendingAdmin.selector;
        selectors[i++] = AdminFacet.acceptAdmin.selector;
        selectors[i++] = AdminFacet.setValidator.selector;
        selectors[i++] = AdminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = AdminFacet.changeFeeParams.selector;
        selectors[i++] = AdminFacet.setTokenMultiplier.selector;
        selectors[i++] = AdminFacet.setPubdataPricingMode.selector;
        selectors[i++] = AdminFacet.setTransactionFilterer.selector;
        selectors[i++] = AdminFacet.setPriorityModeTransactionFilterer.selector;
        selectors[i++] = AdminFacet.permanentlyAllowPriorityMode.selector;
        selectors[i++] = AdminFacet.deactivatePriorityMode.selector;
        selectors[i++] = AdminFacet.activatePriorityMode.selector;
        selectors[i++] = AdminFacet.upgradeChainFromVersion.selector;
        selectors[i++] = AdminFacet.executeUpgrade.selector;
        selectors[i++] = AdminFacet.freezeDiamond.selector;
        selectors[i++] = AdminFacet.unfreezeDiamond.selector;
        selectors[i++] = AdminFacet.genesisUpgrade.selector;
        selectors[i++] = AdminFacet.setDAValidatorPair.selector;
        return selectors;
    }

    function getMigratorSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        uint256 i = 0;
        selectors[i++] = MigratorFacet.pauseDepositsBeforeInitiatingMigration.selector;
        selectors[i++] = MigratorFacet.unpauseDeposits.selector;
        selectors[i++] = MigratorFacet.forwardedBridgeBurn.selector;
        selectors[i++] = MigratorFacet.forwardedBridgeMint.selector;
        selectors[i++] = MigratorFacet.forwardedBridgeConfirmTransferResult.selector;
        selectors[i++] = MigratorFacet.prepareChainCommitment.selector;
        return selectors;
    }

    function getExecutorSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        uint256 i = 0;
        selectors[i++] = ExecutorFacet.proveBatchesSharedBridge.selector;
        selectors[i++] = ExecutorFacet.executeBatchesSharedBridge.selector;
        selectors[i++] = ExecutorFacet.revertBatchesSharedBridge.selector;
        return selectors;
    }

    function getCommitterSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        uint256 i = 0;
        selectors[i++] = CommitterFacet.commitBatchesSharedBridge.selector;
        return selectors;
    }

    function getGettersSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](32);
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
        selectors[i++] = GettersFacet.getZKsyncOS.selector;

        return selectors;
    }

    function getMailboxSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        uint256 i = 0;
        selectors[i++] = MailboxFacet.bridgehubRequestL2Transaction.selector;
        selectors[i++] = MailboxFacet.bridgehubRequestL2TransactionOnGateway.selector;
        selectors[i++] = MailboxFacet.l2TransactionBaseCost.selector;
        selectors[i++] = MailboxFacet.requestL2TransactionToGatewayMailbox.selector;
        selectors[i++] = MailboxFacet.requestL2ServiceTransaction.selector;
        return selectors;
    }

    function getUtilsFacetSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](69);

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
        selectors[i++] = UtilsFacet.util_setPendingAdmin.selector;
        selectors[i++] = UtilsFacet.util_getPendingAdmin.selector;
        selectors[i++] = UtilsFacet.util_setAdmin.selector;
        selectors[i++] = UtilsFacet.util_getAdmin.selector;
        selectors[i++] = UtilsFacet.util_setValidator.selector;
        selectors[i++] = UtilsFacet.util_getValidator.selector;
        selectors[i++] = UtilsFacet.util_getTransactionFilterer.selector;
        selectors[i++] = UtilsFacet.util_setPriorityModeCanBeActivated.selector;
        selectors[i++] = UtilsFacet.util_getPriorityModeCanBeActivated.selector;
        selectors[i++] = UtilsFacet.util_setPriorityModeActivated.selector;
        selectors[i++] = UtilsFacet.util_getPriorityModeActivated.selector;
        selectors[i++] = UtilsFacet.util_setPriorityModePermissionlessValidator.selector;
        selectors[i++] = UtilsFacet.util_getPriorityModePermissionlessValidator.selector;
        selectors[i++] = UtilsFacet.util_setPriorityModeTransactionFilterer.selector;
        selectors[i++] = UtilsFacet.util_getPriorityModeTransactionFilterer.selector;
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
        selectors[i++] = UtilsFacet.util_setL2DACommitmentScheme.selector;
        selectors[i++] = UtilsFacet.util_setSettlementLayer.selector;
        selectors[i++] = UtilsFacet.util_getSettlementLayer.selector;
        selectors[i++] = UtilsFacet.util_setPausedDepositsTimestamp.selector;
        selectors[i++] = UtilsFacet.util_getPausedDepositsTimestamp.selector;
        selectors[i++] = UtilsFacet.util_setNativeTokenVault.selector;
        selectors[i++] = UtilsFacet.util_setIsPermanentRollup.selector;
        selectors[i++] = UtilsFacet.util_setTotalBatchesVerified.selector;
        selectors[i++] = UtilsFacet.util_getTotalBatchesVerified.selector;
        selectors[i++] = UtilsFacet.util_getTotalBatchesExecuted.selector;
        selectors[i++] = UtilsFacet.util_getTotalBatchesCommitted.selector;
        selectors[i++] = UtilsFacet.util_setL2SystemContractsUpgradeBatchNumber.selector;
        selectors[i++] = UtilsFacet.util_getL2SystemContractsUpgradeBatchNumber.selector;
        selectors[i++] = UtilsFacet.util_setL2SystemContractsUpgradeTxHash.selector;
        selectors[i++] = UtilsFacet.util_getL2SystemContractsUpgradeTxHash.selector;
        selectors[i++] = UtilsFacet.util_setPriorityTreeNextLeafIndex.selector;
        selectors[i++] = UtilsFacet.util_setPriorityOpsRequestTimestamp.selector;
        selectors[i++] = UtilsFacet.util_setZKsyncOSMaxTxGasLimit.selector;
        selectors[i++] = UtilsFacet.util_getZKsyncOSMaxTxGasLimit.selector;
        selectors[i++] = UtilsFacet.util_setBaseTokenHasTotalSupply.selector;
        selectors[i++] = UtilsFacet.util_getPubdataContent.selector;
        selectors[i++] = UtilsFacet.util_setDeprecatedPrecommitmentForTheLatestBatch.selector;
        selectors[i++] = UtilsFacet.util_getDeprecatedPrecommitmentForTheLatestBatch.selector;

        return selectors;
    }

    function makeVerifier(address testnetVerifier) public pure returns (IVerifier) {
        return IVerifier(testnetVerifier);
    }

    function makeInitializeData(address bridgehub) public pure returns (InitializeData memory) {
        return
            InitializeData({
                chainId: 1,
                bridgehub: bridgehub,
                chainTypeManager: address(0x1234567890876543567890),
                protocolVersion: 0,
                admin: address(0x32149872498357874258787),
                validatorTimelock: address(0x85430237648403822345345),
                baseTokenAssetId: bytes32(uint256(0x923645439232223445)),
                storedBatchZero: bytes32(0)
            });
    }

    function makeDiamondProxy(Diamond.FacetCut[] memory facetCuts, address bridgehub) public returns (address) {
        DiamondInit diamondInit = new DiamondInit();
        bytes memory diamondInitData = abi.encodeWithSelector(
            diamondInit.initialize.selector,
            makeInitializeData(bridgehub)
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

    /// @dev Historical alias from the dual-VM era; identical to {makeDiamondProxy}.
    function makeZKsyncOSDiamondProxy(
        Diamond.FacetCut[] memory _facetCuts,
        address _bridgehub
    ) public returns (address) {
        return makeDiamondProxy(_facetCuts, _bridgehub);
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

    function constructRollupL2DAValidatorOutputHash(
        bytes32 _stateDiffHash,
        bytes32 _totalPubdataHash,
        uint8 _blobsAmount,
        bytes32[] memory _blobHashes
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_stateDiffHash, _totalPubdataHash, _blobsAmount, _blobHashes));
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
