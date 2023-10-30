// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./Base.sol";
import "../libraries/Diamond.sol";
import "../libraries/PriorityQueue.sol";
import "../../common/libraries/UncheckedMath.sol";
import "../interfaces/IGetters.sol";
import "../interfaces/ILegacyGetters.sol";

/// @title Getters Contract implements functions for getting contract state from outside the batchchain.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract GettersFacet is Base, IGetters, ILegacyGetters {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    string public constant override getName = "GettersFacet";

    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @return The address of the verifier smart contract
    function getVerifier() external view returns (address) {
        return address(s.verifier);
    }

    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return s.governor;
    }

    /// @return The address of the pending governor
    function getPendingGovernor() external view returns (address) {
        return s.pendingGovernor;
    }

    /// @return The total number of batches that were committed
    function getTotalBatchesCommitted() external view returns (uint256) {
        return s.totalBatchesCommitted;
    }

    /// @return The total number of batches that were committed & verified
    function getTotalBatchesVerified() external view returns (uint256) {
        return s.totalBatchesVerified;
    }

    /// @return The total number of batches that were committed & verified & executed
    function getTotalBatchesExecuted() external view returns (uint256) {
        return s.totalBatchesExecuted;
    }

    /// @return The total number of priority operations that were added to the priority queue, including all processed ones
    function getTotalPriorityTxs() external view returns (uint256) {
        return s.priorityQueue.getTotalPriorityTxs();
    }

    /// @notice Returns zero if and only if no operations were processed from the queue
    /// @notice Reverts if there are no unprocessed priority transactions
    /// @return Index of the oldest priority operation that wasn't processed yet
    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return s.priorityQueue.getFirstUnprocessedPriorityTx();
    }

    /// @return The number of priority operations currently in the queue
    function getPriorityQueueSize() external view returns (uint256) {
        return s.priorityQueue.getSize();
    }

    /// @return The first unprocessed priority operation from the queue
    function priorityQueueFrontOperation() external view returns (PriorityOperation memory) {
        return s.priorityQueue.front();
    }

    /// @return Whether the address has a validator access
    function isValidator(address _address) external view returns (bool) {
        return s.validators[_address];
    }

    /// @return Merkle root of the tree with L2 logs for the selected batch
    function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32) {
        return s.l2LogsRootHashes[_batchNumber];
    }

    /// @notice For unfinalized (non executed) batches may change
    /// @dev returns zero for non-committed batches
    /// @return The hash of committed L2 batch.
    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32) {
        return s.storedBatchHashes[_batchNumber];
    }

    /// @return Bytecode hash of bootloader program.
    function getL2BootloaderBytecodeHash() external view returns (bytes32) {
        return s.l2BootloaderBytecodeHash;
    }

    /// @return Bytecode hash of default account (bytecode for EOA).
    function getL2DefaultAccountBytecodeHash() external view returns (bytes32) {
        return s.l2DefaultAccountBytecodeHash;
    }

    /// @return Verifier parameters.
    function getVerifierParams() external view returns (VerifierParams memory) {
        return s.verifierParams;
    }

    /// @return The current protocol version
    function getProtocolVersion() external view returns (uint256) {
        return s.protocolVersion;
    }

    /// @return The upgrade system contract transaction hash, 0 if the upgrade is not initialized
    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }

    /// @return The L2 batch number in which the upgrade transaction was processed.
    /// @dev It is equal to 0 in the following two cases:
    /// - No upgrade transaction has ever been processed.
    /// - The upgrade transaction has been processed and the batch with such transaction has been
    /// executed (i.e. finalized).
    function getL2SystemContractsUpgradeBatchNumber() external view returns (uint256) {
        return s.l2SystemContractsUpgradeBatchNumber;
    }

    /// @return Whether the diamond is frozen or not
    function isDiamondStorageFrozen() external view returns (bool) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.isFrozen;
    }

    /// @return isFreezable Whether the facet can be frozen by the governor or always accessible
    function isFacetFreezable(address _facet) external view returns (bool isFreezable) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        // There is no direct way to get whether the facet address is freezable,
        // so we get it from one of the selectors that are associated with the facet.
        uint256 selectorsArrayLen = ds.facetToSelectors[_facet].selectors.length;
        if (selectorsArrayLen != 0) {
            bytes4 selector0 = ds.facetToSelectors[_facet].selectors[0];
            isFreezable = ds.selectorToFacet[selector0].isFreezable;
        }
    }

    /// @return The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return s.priorityTxMaxGasLimit;
    }

    /// @return The allow list smart contract
    function getAllowList() external view returns (address) {
        return address(s.allowList);
    }

    /// @return Whether the selector can be frozen by the governor or always accessible
    function isFunctionFreezable(bytes4 _selector) external view returns (bool) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        require(ds.selectorToFacet[_selector].facetAddress != address(0), "g2");
        return ds.selectorToFacet[_selector].isFreezable;
    }

    /// @return Whether a withdrawal has been finalized.
    /// @param _l2BatchNumber The L2 batch number within which the withdrawal happened.
    /// @param _l2MessageIndex The index of the L2->L1 message denoting the withdrawal.
    function isEthWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool) {
        return s.isEthWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex];
    }

    /*//////////////////////////////////////////////////////////////
                            DIAMOND LOUPE
     //////////////////////////////////////////////////////////////*/

    /// @return result All facet addresses and their function selectors
    function facets() external view returns (Facet[] memory result) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        uint256 facetsLen = ds.facets.length;
        result = new Facet[](facetsLen);

        for (uint256 i = 0; i < facetsLen; i = i.uncheckedInc()) {
            address facetAddr = ds.facets[i];
            Diamond.FacetToSelectors memory facetToSelectors = ds.facetToSelectors[facetAddr];

            result[i] = Facet(facetAddr, facetToSelectors.selectors);
        }
    }

    /// @return NON-sorted array with function selectors supported by a specific facet
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.facetToSelectors[_facet].selectors;
    }

    /// @return NON-sorted array of facet addresses supported on diamond
    function facetAddresses() external view returns (address[] memory) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.facets;
    }

    /// @return Facet address associated with a selector. Zero if the selector is not added to the diamond
    function facetAddress(bytes4 _selector) external view returns (address) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.selectorToFacet[_selector].facetAddress;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPRECATED METHODS
    //////////////////////////////////////////////////////////////*/

    /// @return The total number of batches that were committed
    /// @dev It is a *deprecated* method, please use `getTotalBatchesCommitted` instead
    function getTotalBlocksCommitted() external view returns (uint256) {
        return s.totalBatchesCommitted;
    }

    /// @return The total number of batches that were committed & verified
    /// @dev It is a *deprecated* method, please use `getTotalBatchesVerified` instead.
    function getTotalBlocksVerified() external view returns (uint256) {
        return s.totalBatchesVerified;
    }

    /// @return The total number of batches that were committed & verified & executed
    /// @dev It is a *deprecated* method, please use `getTotalBatchesExecuted` instead.
    function getTotalBlocksExecuted() external view returns (uint256) {
        return s.totalBatchesExecuted;
    }

    /// @notice For unfinalized (non executed) batches may change
    /// @dev It is a *deprecated* method, please use `storedBatchHash` instead.
    /// @dev returns zero for non-committed batches
    /// @return The hash of committed L2 batch.
    function storedBlockHash(uint256 _batchNumber) external view returns (bytes32) {
        return s.storedBatchHashes[_batchNumber];
    }

    /// @return The L2 batch number in which the upgrade transaction was processed.
    /// @dev It is a *deprecated* method, please use `getL2SystemContractsUpgradeBatchNumber` instead.
    /// @dev It is equal to 0 in the following two cases:
    /// - No upgrade transaction has ever been processed.
    /// - The upgrade transaction has been processed and the batch with such transaction has been
    /// executed (i.e. finalized).
    function getL2SystemContractsUpgradeBlockNumber() external view returns (uint256) {
        return s.l2SystemContractsUpgradeBatchNumber;
    }
}
