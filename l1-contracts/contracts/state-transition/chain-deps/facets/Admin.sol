// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAdmin} from "../../chain-interfaces/IAdmin.sol";

import {IBridgehub} from "../../../bridgehub/IBridgehub.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_GAS_PER_TRANSACTION, HyperchainCommitment, StoredBatchHashInfo, SYSTEM_UPGRADE_L2_TX_TYPE, PRIORITY_TX_MAX_GAS_LIMIT} from "../../../common/Config.sol";
import {FeeParams, PubdataPricingMode, SyncLayerState} from "../ZkSyncHyperchainStorage.sol";
import {PriorityQueue, PriorityOperation} from "../../../state-transition/libraries/PriorityQueue.sol";
import {ZkSyncHyperchainBase} from "./ZkSyncHyperchainBase.sol";
import {IStateTransitionManager} from "../../IStateTransitionManager.sol";
import {ISystemContext} from "../../l2-deps/ISystemContext.sol";
import {PriorityOperation} from "../../libraries/PriorityQueue.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../../../common/L2ContractAddresses.sol";
import {L2CanonicalTransaction, TxStatus} from "../../../common/Messaging.sol";
import {ProposedUpgrade} from "../../../upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "../../chain-interfaces/IVerifier.sol";
import {IDefaultUpgrade} from "../../../upgrades/IDefaultUpgrade.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZkSyncHyperchainBase} from "../../chain-interfaces/IZkSyncHyperchainBase.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract AdminFacet is ZkSyncHyperchainBase, IAdmin {
    using PriorityQueue for PriorityQueue.Queue;

    /// @inheritdoc IZkSyncHyperchainBase
    string public constant override getName = "AdminFacet";

    /// @inheritdoc IAdmin
    function setPendingAdmin(address _newPendingAdmin) external onlyAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = s.pendingAdmin;
        // Change pending admin
        s.pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IAdmin
    function acceptAdmin() external {
        address pendingAdmin = s.pendingAdmin;
        require(msg.sender == pendingAdmin, "n4"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = s.admin;
        s.admin = pendingAdmin;
        delete s.pendingAdmin;

        emit NewPendingAdmin(pendingAdmin, address(0));
        emit NewAdmin(previousAdmin, pendingAdmin);
    }

    /// @inheritdoc IAdmin
    function setValidator(address _validator, bool _active) external onlyStateTransitionManager {
        s.validators[_validator] = _active;
        emit ValidatorStatusUpdate(_validator, _active);
    }

    /// @inheritdoc IAdmin
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyStateTransitionManager {
        // Change the porter availability
        s.zkPorterIsAvailable = _zkPorterIsAvailable;
        emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
    }

    /// @inheritdoc IAdmin
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyStateTransitionManager {
        require(_newPriorityTxMaxGasLimit <= MAX_GAS_PER_TRANSACTION, "n5");

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }

    /// @inheritdoc IAdmin
    function changeFeeParams(FeeParams calldata _newFeeParams) external onlyAdminOrStateTransitionManager {
        // Double checking that the new fee params are valid, i.e.
        // the maximal pubdata per batch is not less than the maximal pubdata per priority transaction.
        require(_newFeeParams.maxPubdataPerBatch >= _newFeeParams.priorityTxMaxPubdata, "n6");

        FeeParams memory oldFeeParams = s.feeParams;

        require(_newFeeParams.pubdataPricingMode == oldFeeParams.pubdataPricingMode, "n7"); // we cannot change pubdata pricing mode

        s.feeParams = _newFeeParams;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /// @inheritdoc IAdmin
    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external onlyAdminOrStateTransitionManager {
        require(_denominator != 0, "AF: denominator 0");
        uint128 oldNominator = s.baseTokenGasPriceMultiplierNominator;
        uint128 oldDenominator = s.baseTokenGasPriceMultiplierDenominator;

        s.baseTokenGasPriceMultiplierNominator = _nominator;
        s.baseTokenGasPriceMultiplierDenominator = _denominator;

        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, _nominator, _denominator);
    }

    /// @inheritdoc IAdmin
    function setPubdataPricingMode(PubdataPricingMode _pricingMode) external onlyAdmin {
        require(s.totalBatchesCommitted == 0, "AdminFacet: set validium only after genesis"); // Validium mode can be set only before the first batch is processed
        s.feeParams.pubdataPricingMode = _pricingMode;
        emit ValidiumModeStatusUpdate(_pricingMode);
    }

    function setTransactionFilterer(address _transactionFilterer) external onlyAdmin {
        address oldTransactionFilterer = s.transactionFilterer;
        s.transactionFilterer = _transactionFilterer;
        emit NewTransactionFilterer(oldTransactionFilterer, _transactionFilterer);
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function upgradeChainFromVersion(
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyAdminOrStateTransitionManager {
        bytes32 cutHashInput = keccak256(abi.encode(_diamondCut));
        require(
            cutHashInput == IStateTransitionManager(s.stateTransitionManager).upgradeCutHash(_oldProtocolVersion),
            "AdminFacet: cutHash mismatch"
        );

        require(s.protocolVersion == _oldProtocolVersion, "AdminFacet: protocolVersion mismatch in STC when upgrading");
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
        require(s.protocolVersion > _oldProtocolVersion, "AdminFacet: protocolVersion mismatch in STC after upgrading");
    }

    /// @inheritdoc IAdmin
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external onlyStateTransitionManager {
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
    }

    /// @dev we have to set the chainId at genesis, as blockhashzero is the same for all chains with the same chainId
    function setChainIdUpgrade(address _genesisUpgrade) external onlyStateTransitionManager {
        uint256 currentProtocolVersion = s.protocolVersion;
        uint256 chainId = s.chainId;

        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (chainId));
        uint256[] memory uintEmptyArray;
        bytes[] memory bytesEmptyArray;

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR)),
            gasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the protocol version is used as "nonce" for system upgrade transactions
            nonce: currentProtocolVersion,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: systemContextCalldata,
            signature: new bytes(0),
            factoryDeps: uintEmptyArray,
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: bytesEmptyArray,
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            verifier: address(0),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: currentProtocolVersion
        });

        Diamond.FacetCut[] memory emptyArray;
        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: _genesisUpgrade,
            initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
        });

        Diamond.diamondCut(cutData);
        emit SetChainIdUpgrade(address(this), l2ProtocolUpgradeTx, currentProtocolVersion);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT FREEZING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function freezeDiamond() external onlyStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(!diamondStorage.isFrozen, "a9"); // diamond proxy is frozen already
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @inheritdoc IAdmin
    function unfreezeDiamond() external onlyStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }

    /*//////////////////////////////////////////////////////////////
                            CHAIN MIGRATION
    //////////////////////////////////////////////////////////////*/

    /// @dev we can move assets using these
    function bridgeBurn(
        uint256 _settlementChainId,
        uint256 _mintValue,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridgehub returns (bytes memory chainBridgeMintData) {
        (address _newSyncLayerAdmin, bytes memory _diamondCut) = abi.decode(_data, (address, bytes));

        require(_prevMsgSender == s.admin, "BH: not chainAdmin");
        IStateTransitionManager stm = IStateTransitionManager(s.stateTransitionManager);

        require(_newSyncLayerAdmin != address(0), "STM: admin zero");

        // address chainBaseToken = hyperchain.getBaseToken();
        uint256 currentProtocolVersion = s.protocolVersion;
        uint256 protocolVersion = stm.protocolVersion();

        require(currentProtocolVersion == protocolVersion, "STM: protocolVersion not up to date");
        // FIXME: this will be removed once we support the migration of the priority queue also.
        require(s.priorityQueue.getSize() == 0, "Migration is only allowed with empty priority queue");
        bytes memory chainData = _collectChainDataForMigration();
        bytes memory stmData = abi.encode(_newSyncLayerAdmin, currentProtocolVersion, chainData, _diamondCut); // todo
        chainBridgeMintData = abi.encode(stmData, chainData); // todo
    }

    function _collectChainDataForMigration() internal view returns (bytes memory chainData) {
        // todo
    }

    function bridgeMint(uint256 _chainId, bytes32 _assetInfo, bytes calldata _data) external payable override {}

    // /// @inheritdoc IAdmin
    // function finalizeMigration(HyperchainCommitment memory _commitment) external onlyStateTransitionManager {
    //     if (s.syncLayerState == SyncLayerState.MigratedFromL1) {
    //         s.syncLayerState = SyncLayerState.ActiveOnL1;
    //     } else if (s.syncLayerState == SyncLayerState.MigratedFromSL) {
    //         s.syncLayerState = SyncLayerState.ActiveOnSL;
    //     } else {
    //         revert("Can not migrate when in active state");
    //     }

    //     uint256 batchesExecuted = _commitment.totalBatchesExecuted;
    //     uint256 batchesVerified = _commitment.totalBatchesVerified;
    //     uint256 batchesCommitted = _commitment.totalBatchesCommitted;

    //     s.totalBatchesCommitted = batchesCommitted;
    //     s.totalBatchesVerified = batchesVerified;
    //     s.totalBatchesExecuted = batchesExecuted;

    //     // Some consistency checks just in case.
    //     require(batchesExecuted <= batchesVerified, "Executed is not consistent with verified");
    //     require(batchesVerified <= batchesCommitted, "Verified is not consistent with committed");

    //     // In the worst case, we may need to revert all the committed batches that were not executed.
    //     // This means that the stored batch hashes should be stored for [batchesExecuted; batchesCommitted] batches, i.e.
    //     // there should be batchesCommitted - batchesExecuted + 1 hashes.
    //     require(
    //         _commitment.batchHashes.length == batchesCommitted - batchesExecuted + 1,
    //         "Invalid number of batch hashes"
    //     );

    //     // Note that this part is done in O(N), i.e. it is the responsibility of the admin of the chain to ensure that the total number of
    //     // outstanding committed batches is not too long.
    //     for (uint256 i = 0; i < _commitment.batchHashes.length; i++) {
    //         s.storedBatchHashes[batchesExecuted + i] = _commitment.batchHashes[i];
    //     }

    //     // Currently only zero length is allowed.
    //     uint256 pqHead = _commitment.priorityQueueHead;
    //     s.priorityQueue.head = pqHead;
    //     s.priorityQueue.tail = pqHead + _commitment.priorityQueueTxs.length;

    //     for (uint256 i = 0; i < _commitment.priorityQueueTxs.length; i++) {
    //         s.priorityQueue.data[pqHead + i] = _commitment.priorityQueueTxs[i];
    //     }

    //     s.l2SystemContractsUpgradeTxHash = _commitment.l2SystemContractsUpgradeTxHash;
    //     s.l2SystemContractsUpgradeBatchNumber = _commitment.l2SystemContractsUpgradeBatchNumber;

    //     emit MigrationComplete();
    // }

    // // FI
    // // function becomeSyncLayer() external onlyStateTransitionManager {
    // //     require(s.syncLayerState == SyncLayerState.ActiveOnL1, "not active L1");
    // //     // TODO: possibly additional checks
    // //     s.syncLayerState = SyncLayerState.SyncLayerL1;
    // // }

    // function startMigrationToSyncLayer(
    //     uint256 _syncLayerChainId,
    //     address _stmCounterPart,
    //     address _newSyncLayerAdmin,
    //     bytes calldata _diamondCut
    // ) external onlyStateTransitionManager returns (bytes memory migrationCalldata) {
    //     // TODO: add a check that there are no outstanding upgrades.

    //     // FIXME: uncomment
    //     require(s.syncLayerState == SyncLayerState.ActiveOnL1, "not active L1");
    //     s.syncLayerState = SyncLayerState.MigratedFromL1;
    //     s.syncLayerChainId = _syncLayerChainId;

    //     HyperchainCommitment memory commitment = _prepareChainCommitment();

    //     migrationCalldata = abi.encodeCall(
    //         IStateTransitionManager.finalizeMigrationToSyncLayer,
    //         (s.chainId, s.baseToken, _stmCounterPart, _newSyncLayerAdmin, s.protocolVersion, commitment, _diamondCut)
    //     );
    // }

    // function storeMigrationHash(bytes32 _migrationHash) external onlyStateTransitionManager {
    //     s.syncLayerMigrationHash = _migrationHash;
    // }
    // function recoverFromFailedMigrationToSyncLayer(
    //     uint256 _syncLayerChainId,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes32[] calldata _merkleProof
    // ) external onlyAdmin {
    //     require(s.syncLayerState == SyncLayerState.MigratedFromL1, "not migrated L1");

    //     bytes32 migrationHash = s.syncLayerMigrationHash;
    //     require(migrationHash != bytes32(0), "can not recover when there is no migration");

    //     require(
    //         IBridgehub(s.bridgehub).proveL1ToL2TransactionStatus(
    //             _syncLayerChainId,
    //             migrationHash,
    //             _l2BatchNumber,
    //             _l2MessageIndex,
    //             _l2TxNumberInBatch,
    //             _merkleProof,
    //             TxStatus.Failure
    //         ),
    //         "Migration not failed"
    //     );

    //     s.syncLayerState = SyncLayerState.ActiveOnL1;
    //     s.syncLayerChainId = 0;
    //     s.syncLayerMigrationHash = bytes32(0);

    //     // We do not need to perform any additional actions, since no changes related to the chain commitment can be performed
    //     // while the chain is in the "migrated" state.
    // }

    // FI
    // function becomeSyncLayer() external onlyStateTransitionManager {
    //     require(s.syncLayerState == SyncLayerState.ActiveOnL1, "not active L1");
    //     // TODO: possibly additional checks
    //     s.syncLayerState = SyncLayerState.SyncLayerL1;
    // }

    // function _prepareChainCommitment() internal returns (HyperchainCommitment memory commitment) {
    //     commitment.totalBatchesCommitted = s.totalBatchesCommitted;
    //     commitment.totalBatchesVerified = s.totalBatchesVerified;
    //     commitment.totalBatchesExecuted = s.totalBatchesExecuted;

    //     uint256 pqHead = s.priorityQueue.head;
    //     commitment.priorityQueueHead = pqHead;

    //     uint256 pqLength = s.priorityQueue.tail - pqHead;
    //     // FIXME: this will be removed once we support the migration of any priority queue size.
    //     require(pqLength <= 50, "Migration is only allowed with empty priority queue");

    //     PriorityOperation[] memory priorityQueueTxs = new PriorityOperation[](pqLength);

    //     for (uint256 i = pqHead; i < s.priorityQueue.tail; i++) {
    //         priorityQueueTxs[i] = s.priorityQueue.data[i];
    //     }
    //     commitment.priorityQueueTxs = priorityQueueTxs;

    //     commitment.l2SystemContractsUpgradeBatchNumber = s.l2SystemContractsUpgradeBatchNumber;
    //     commitment.l2SystemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;

    //     // just in case
    //     require(
    //         commitment.totalBatchesExecuted <= commitment.totalBatchesVerified,
    //         "Verified is not consistent with executed"
    //     );
    //     require(
    //         commitment.totalBatchesVerified <= commitment.totalBatchesCommitted,
    //         "Verified is not consistent with committed"
    //     );

    //     uint256 blocksToRemember = commitment.totalBatchesCommitted - commitment.totalBatchesExecuted + 1;

    //     bytes32[] memory batchHashes = new bytes32[](blocksToRemember);

    //     for (uint256 i = 0; i < blocksToRemember; i++) {
    //         unchecked {
    //             batchHashes[i] = s.storedBatchHashes[commitment.totalBatchesExecuted + i];
    //         }
    //     }

    //     commitment.batchHashes = batchHashes;
    // }

    // function finalizeMigrationFromSyncLayer(uint256 _chainId) external {
    //     // FIXME: this method should check that a certain message was sent from the SL to L1.
    //     require(false, "TODO");
    //     // address currentAddress = getHyperchain(_chainId);
    //     // // On L1 we do expect that the chain is already registered.
    //     // require(currentAddress != address(0), "STM: chain not registered");
    //     // _finalizeMigration(
    //     //     _chainId,
    //     //     _baseToken,
    //     //     _sharedBridge,
    //     //     _admin,
    //     //     _expectedProtocolVersion,
    //     //     commitment
    //     // );
    // }

    // function startMigrationToSyncLayer(
    //     uint256 _chainId,
    //     uint256 _syncLayerChainId,
    //     address _newSyncLayerAdmin,
    //     // L2TransactionRequestDirect memory _request,
    //     bytes calldata _diamondCut
    // ) external payable {
    //     // TODO: Maybe check l2 diamond cut here for failing fast?
    //     // lastMigrationTxHashes[_chainId] = canonicalHash;
    //     // hyperchain.storeMigrationHash(canonicalHash);
    //     // lastMigratedCommitments[_chainId] = keccak256(abi.encode(commitment));
    //     // Now, we need to send an L1->L2 tx to the sync layer blockchain to the spawn the chain on SL.
    //     // We just send it via a normal L-Z
    // }

    function bridgeClaimFailedBurn(
        uint256 _chainId,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override {}
}
