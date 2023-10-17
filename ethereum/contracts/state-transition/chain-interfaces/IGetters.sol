// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "../libraries/PriorityQueue.sol";
import {VerifierParams, ProofUpgradeState} from "../chain-deps/StateTransitionChainStorage.sol";
import "./IBase.sol";

interface IGetters is IStateTransitionChainBase {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    function getBridgehub() external view returns (address);

    function getVerifier() external view returns (address);

    function getGovernor() external view returns (address);

    function getPendingGovernor() external view returns (address);

    function getTotalBatchesCommitted() external view returns (uint256);

    function getTotalBatchesVerified() external view returns (uint256);

    function getTotalBatchesExecuted() external view returns (uint256);

    // function getTotalPriorityTxs() external view returns (uint256);

    // function getFirstUnprocessedPriorityTx() external view returns (uint256);

    // function getPriorityQueueSize() external view returns (uint256);

    // function priorityQueueFrontOperation() external view returns (PriorityOperation memory);

    function isValidator(address _address) external view returns (bool);

    // function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32 hash);

    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32);

    function getL2BootloaderBytecodeHash() external view returns (bytes32);

    function getL2DefaultAccountBytecodeHash() external view returns (bytes32);

    function getVerifierParams() external view returns (VerifierParams memory);

    // function getSecurityCouncil() external view returns (address);

    // function getUpgradeProposalState() external view returns (ProofUpgradeState);

    // function getProposedUpgradeHash() external view returns (bytes32);

    // function getProposedUpgradeTimestamp() external view returns (uint256);

    // function getCurrentProposalId() external view returns (uint256);

    function getProtocolVersion() external view returns (uint256);

    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32);

    function getL2SystemContractsUpgradeBatchNumber() external view returns (uint256);

    function isDiamondStorageFrozen() external view returns (bool);

    // KL todo: remove this?
    function getPriorityTxMaxGasLimit() external view returns (uint256);

    function getAllowList() external view returns (address);

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

    function facets() external view returns (Facet[] memory);

    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory);

    function facetAddresses() external view returns (address[] memory facets);

    function facetAddress(bytes4 _selector) external view returns (address facet);

    function isFunctionFreezable(bytes4 _selector) external view returns (bool);

    function isFacetFreezable(address _facet) external view returns (bool isFreezable);
}
