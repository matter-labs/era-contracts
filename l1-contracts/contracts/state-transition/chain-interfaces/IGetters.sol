// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityOperation} from "../libraries/PriorityQueue.sol";
import {VerifierParams} from "../chain-interfaces/IVerifier.sol";
import {PubdataPricingMode} from "../chain-deps/ZkSyncHyperchainStorage.sol";
import {IZkSyncHyperchainBase} from "./IZkSyncHyperchainBase.sol";

/// @title The interface of the Getters Contract that implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IGetters is IZkSyncHyperchainBase {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @return The address of the verifier smart contract
    function getVerifier() external view returns (address);

    /// @return The address of the current admin
    function getAdmin() external view returns (address);

    /// @return The address of the pending admin
    function getPendingAdmin() external view returns (address);

    /// @return The address of the bridgehub
    function getBridgehub() external view returns (address);

    /// @return The address of the state transition
    function getStateTransitionManager() external view returns (address);

    /// @return The address of the base token
    function getBaseToken() external view returns (address);

    /// @return The address of the base token bridge
    function getBaseTokenBridge() external view returns (address);

    /// @return The total number of batches that were committed
    function getTotalBatchesCommitted() external view returns (uint256);

    /// @return The total number of batches that were committed & verified
    function getTotalBatchesVerified() external view returns (uint256);

    /// @return The total number of batches that were committed & verified & executed
    function getTotalBatchesExecuted() external view returns (uint256);

    /// @return The total number of priority operations that were added to the priority queue, including all processed ones
    function getTotalPriorityTxs() external view returns (uint256);

    /// @notice The function that returns the first unprocessed priority transaction.
    /// @dev Returns zero if and only if no operations were processed from the queue.
    /// @dev If all the transactions were processed, it will return the last processed index, so
    /// in case exactly *unprocessed* transactions are needed, one should check that getPriorityQueueSize() is greater than 0.
    /// @return Index of the oldest priority operation that wasn't processed yet
    function getFirstUnprocessedPriorityTx() external view returns (uint256);

    /// @return The number of priority operations currently in the queue
    function getPriorityQueueSize() external view returns (uint256);

    /// @return The first unprocessed priority operation from the queue
    function priorityQueueFrontOperation() external view returns (PriorityOperation memory);

    /// @return Whether the address has a validator access
    function isValidator(address _address) external view returns (bool);

    /// @return merkleRoot Merkle root of the tree with L2 logs for the selected batch
    function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32 merkleRoot);

    /// @notice For unfinalized (non executed) batches may change
    /// @dev returns zero for non-committed batches
    /// @return The hash of committed L2 batch.
    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32);

    /// @return Bytecode hash of bootloader program.
    function getL2BootloaderBytecodeHash() external view returns (bytes32);

    /// @return Bytecode hash of default account (bytecode for EOA).
    function getL2DefaultAccountBytecodeHash() external view returns (bytes32);

    /// @return Verifier parameters.
    /// @dev This function is deprecated and will soon be removed.
    function getVerifierParams() external view returns (VerifierParams memory);

    /// @return Whether the diamond is frozen or not
    function isDiamondStorageFrozen() external view returns (bool);

    /// @return The current packed protocol version. To access human-readable version, use `getSemverProtocolVersion` function.
    function getProtocolVersion() external view returns (uint256);

    /// @return The tuple of (major, minor, patch) protocol version.
    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32);

    /// @return The upgrade system contract transaction hash, 0 if the upgrade is not initialized
    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32);

    /// @return The L2 batch number in which the upgrade transaction was processed.
    /// @dev It is equal to 0 in the following two cases:
    /// - No upgrade transaction has ever been processed.
    /// - The upgrade transaction has been processed and the batch with such transaction has been
    /// executed (i.e. finalized).
    function getL2SystemContractsUpgradeBatchNumber() external view returns (uint256);

    /// @return The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function getPriorityTxMaxGasLimit() external view returns (uint256);

    /// @return Whether a withdrawal has been finalized.
    /// @param _l2BatchNumber The L2 batch number within which the withdrawal happened.
    /// @param _l2MessageIndex The index of the L2->L1 message denoting the withdrawal.
    function isEthWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool);

    /// @return The pubdata pricing mode.
    function getPubdataPricingMode() external view returns (PubdataPricingMode);

    /// @return the baseTokenGasPriceMultiplierNominator, used to compare the baseTokenPrice to ether for L1->L2 transactions
    function baseTokenGasPriceMultiplierNominator() external view returns (uint128);

    /// @return the baseTokenGasPriceMultiplierDenominator, used to compare the baseTokenPrice to ether for L1->L2 transactions
    function baseTokenGasPriceMultiplierDenominator() external view returns (uint128);

    /*//////////////////////////////////////////////////////////////
                            DIAMOND LOUPE
    //////////////////////////////////////////////////////////////*/

    /// @notice Faсet structure compatible with the EIP-2535 diamond loupe
    /// @param addr The address of the facet contract
    /// @param selectors The NON-sorted array with selectors associated with facet
    struct Facet {
        address addr;
        bytes4[] selectors;
    }

    /// @return result All facet addresses and their function selectors
    function facets() external view returns (Facet[] memory);

    /// @return NON-sorted array with function selectors supported by a specific facet
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory);

    /// @return facets NON-sorted array of facet addresses supported on diamond
    function facetAddresses() external view returns (address[] memory facets);

    /// @return facet The facet address associated with a selector. Zero if the selector is not added to the diamond
    function facetAddress(bytes4 _selector) external view returns (address facet);

    /// @return Whether the selector can be frozen by the admin or always accessible
    function isFunctionFreezable(bytes4 _selector) external view returns (bool);

    /// @return isFreezable Whether the facet can be frozen by the admin or always accessible
    function isFacetFreezable(address _facet) external view returns (bool isFreezable);
}
