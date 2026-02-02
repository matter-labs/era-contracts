// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {FeeParams, IVerifier, VerifierParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

contract UtilsFacet is ZKChainBase {
    function util_setChainId(uint256 _chainId) external {
        s.chainId = _chainId;
    }

    function util_getChainId() external view returns (uint256) {
        return s.chainId;
    }

    function util_setBridgehub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }

    function util_getBridgehub() external view returns (address) {
        return s.bridgehub;
    }

    function util_setBaseToken(bytes32 _baseTokenAssetId) external {
        s.baseTokenAssetId = _baseTokenAssetId;
    }

    function util_getBaseTokenAssetId() external view returns (bytes32) {
        return s.baseTokenAssetId;
    }

    function util_setVerifier(IVerifier _verifier) external {
        s.verifier = _verifier;
    }

    function util_getVerifier() external view returns (IVerifier) {
        return s.verifier;
    }

    function util_setStoredBatchHashes(uint32 _batchId, bytes32 _storedBatchHash) external {
        s.storedBatchHashes[_batchId] = _storedBatchHash;
    }

    function util_getStoredBatchHashes(uint32 _batchId) external view returns (bytes32) {
        return s.storedBatchHashes[_batchId];
    }

    function util_setVerifierParams(VerifierParams calldata _verifierParams) external {
        s.__DEPRECATED_verifierParams = _verifierParams;
    }

    function util_getVerifierParams() external view returns (VerifierParams memory) {
        return s.__DEPRECATED_verifierParams;
    }

    function util_setL2BootloaderBytecodeHash(bytes32 _l2BootloaderBytecodeHash) external {
        s.l2BootloaderBytecodeHash = _l2BootloaderBytecodeHash;
    }

    function util_getL2BootloaderBytecodeHash() external view returns (bytes32) {
        return s.l2BootloaderBytecodeHash;
    }

    function util_setL2DefaultAccountBytecodeHash(bytes32 _l2DefaultAccountBytecodeHash) external {
        s.l2DefaultAccountBytecodeHash = _l2DefaultAccountBytecodeHash;
    }

    function util_getL2DefaultAccountBytecodeHash() external view returns (bytes32) {
        return s.l2DefaultAccountBytecodeHash;
    }

    function util_setL2EvmEmulatorBytecodeHash(bytes32 _l2EvmEmulatorBytecodeHash) external {
        s.l2EvmEmulatorBytecodeHash = _l2EvmEmulatorBytecodeHash;
    }

    function util_getL2EvmEmulatorBytecodeHash() external view returns (bytes32) {
        return s.l2EvmEmulatorBytecodeHash;
    }

    function util_setPendingAdmin(address _pendingAdmin) external {
        s.pendingAdmin = _pendingAdmin;
    }

    function util_getPendingAdmin() external view returns (address) {
        return s.pendingAdmin;
    }

    function util_setAdmin(address _admin) external {
        s.admin = _admin;
    }

    function util_getAdmin() external view returns (address) {
        return s.admin;
    }

    function util_setValidator(address _validator, bool _active) external {
        s.validators[_validator] = _active;
    }

    function util_getValidator(address _validator) external view returns (bool) {
        return s.validators[_validator];
    }

    function util_setTransactionFilterer(address _filterer) external {
        s.transactionFilterer = _filterer;
    }

    function util_getTransactionFilterer() external view returns (address) {
        return s.transactionFilterer;
    }

    function util_setPriorityModeCanBeActivated(bool _canBeActivated) external {
        s.priorityModeInfo.canBeActivated = _canBeActivated;
    }

    function util_getPriorityModeCanBeActivated() external view returns (bool) {
        return s.priorityModeInfo.canBeActivated;
    }

    function util_setPriorityModeActivated(bool _activated) external {
        s.priorityModeInfo.activated = _activated;
    }

    function util_getPriorityModeActivated() external view returns (bool) {
        return s.priorityModeInfo.activated;
    }

    function util_setPriorityModePermissionlessValidator(address _permissionlessValidator) external {
        s.priorityModeInfo.permissionlessValidator = _permissionlessValidator;
    }

    function util_getPriorityModePermissionlessValidator() external view returns (address) {
        return s.priorityModeInfo.permissionlessValidator;
    }

    function util_setPriorityModeTransactionFilterer(address _filterer) external {
        s.priorityModeInfo.transactionFilterer = _filterer;
    }

    function util_getPriorityModeTransactionFilterer() external view returns (address) {
        return s.priorityModeInfo.transactionFilterer;
    }

    function util_setBaseTokenGasPriceMultiplierDenominator(uint128 _denominator) external {
        s.baseTokenGasPriceMultiplierDenominator = _denominator;
    }

    function util_setZkPorterAvailability(bool _available) external {
        s.zkPorterIsAvailable = _available;
    }

    function util_getZkPorterAvailability() external view returns (bool) {
        return s.zkPorterIsAvailable;
    }

    function util_setChainTypeManager(address _chainTypeManager) external {
        s.chainTypeManager = _chainTypeManager;
    }

    function util_getChainTypeManager() external view returns (address) {
        return s.chainTypeManager;
    }

    function util_setPriorityTxMaxGasLimit(uint256 _priorityTxMaxGasLimit) external {
        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }

    function util_getPriorityTxMaxGasLimit() external view returns (uint256) {
        return s.priorityTxMaxGasLimit;
    }

    function util_setFeeParams(FeeParams calldata _feeParams) external {
        s.feeParams = _feeParams;
    }

    function util_getFeeParams() external view returns (FeeParams memory) {
        return s.feeParams;
    }

    function util_setProtocolVersion(uint256 _protocolVersion) external {
        s.protocolVersion = _protocolVersion;
    }

    function util_getProtocolVersion() external view returns (uint256) {
        return s.protocolVersion;
    }

    function util_setIsFrozen(bool _isFrozen) external {
        Diamond.DiamondStorage storage s = Diamond.getDiamondStorage();
        s.isFrozen = _isFrozen;
    }

    function util_getIsFrozen() external view returns (bool) {
        Diamond.DiamondStorage storage s = Diamond.getDiamondStorage();
        return s.isFrozen;
    }

    function util_setTotalBatchesExecuted(uint256 _numberOfBatches) external {
        s.totalBatchesExecuted = _numberOfBatches;
    }

    function util_setL2LogsRootHash(uint256 _batchNumber, bytes32 _newHash) external {
        s.l2LogsRootHashes[_batchNumber] = _newHash;
    }

    function util_setBaseTokenGasPriceMultiplierNominator(uint128 _nominator) external {
        s.baseTokenGasPriceMultiplierNominator = _nominator;
    }

    function util_setTotalBatchesCommitted(uint256 _totalBatchesCommitted) external {
        s.totalBatchesCommitted = _totalBatchesCommitted;
    }

    function util_getBaseTokenGasPriceMultiplierDenominator() external view returns (uint128) {
        return s.baseTokenGasPriceMultiplierDenominator;
    }

    function util_getBaseTokenGasPriceMultiplierNominator() external view returns (uint128) {
        return s.baseTokenGasPriceMultiplierNominator;
    }

    function util_getL2DACommimentScheme() external view returns (L2DACommitmentScheme) {
        return s.l2DACommitmentScheme;
    }

    function util_setSettlementLayer(address _settlementLayer) external {
        s.settlementLayer = _settlementLayer;
    }

    function util_getSettlementLayer() external view returns (address) {
        return s.settlementLayer;
    }

    function util_setPausedDepositsTimestamp(uint256 _timestamp) external {
        s.pausedDepositsTimestamp = _timestamp;
    }

    function util_getPausedDepositsTimestamp() external view returns (uint256) {
        return s.pausedDepositsTimestamp;
    }

    function util_setAssetTracker(address _assetTracker) external {
        s.assetTracker = _assetTracker;
    }

    function util_setNativeTokenVault(address _nativeTokenVault) external {
        s.nativeTokenVault = _nativeTokenVault;
    }

    function util_setTotalBatchesVerified(uint256 _totalBatchesVerified) external {
        s.totalBatchesVerified = _totalBatchesVerified;
    }

    function util_getTotalBatchesVerified() external view returns (uint256) {
        return s.totalBatchesVerified;
    }

    function util_getTotalBatchesExecuted() external view returns (uint256) {
        return s.totalBatchesExecuted;
    }

    function util_getTotalBatchesCommitted() external view returns (uint256) {
        return s.totalBatchesCommitted;
    }

    function util_setL2SystemContractsUpgradeBatchNumber(uint256 _batchNumber) external {
        s.l2SystemContractsUpgradeBatchNumber = _batchNumber;
    }

    function util_getL2SystemContractsUpgradeBatchNumber() external view returns (uint256) {
        return s.l2SystemContractsUpgradeBatchNumber;
    }

    function util_setL2SystemContractsUpgradeTxHash(bytes32 _txHash) external {
        s.l2SystemContractsUpgradeTxHash = _txHash;
    }

    function util_getL2SystemContractsUpgradeTxHash() external view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
