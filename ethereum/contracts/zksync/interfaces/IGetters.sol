// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../Storage.sol";
import "../libraries/PriorityQueue.sol";
import {VerifierParams} from "../Storage.sol";

interface IGetters {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    function getVerifier() external view returns (address);

    function getGovernor() external view returns (address);

    function getPendingGovernor() external view returns (address);

    function getTotalBlocksCommitted() external view returns (uint256);

    function getTotalBlocksVerified() external view returns (uint256);

    function getTotalBlocksExecuted() external view returns (uint256);

    function getTotalPriorityTxs() external view returns (uint256);

    function getFirstUnprocessedPriorityTx() external view returns (uint256);

    function getPriorityQueueSize() external view returns (uint256);

    function priorityQueueFrontOperation() external view returns (PriorityOperation memory);

    function isValidator(address _address) external view returns (bool);

    function l2LogsRootHash(uint256 _blockNumber) external view returns (bytes32 hash);

    function storedBlockHash(uint256 _blockNumber) external view returns (bytes32);

    function getL2BootloaderBytecodeHash() external view returns (bytes32);

    function getL2DefaultAccountBytecodeHash() external view returns (bytes32);

    function getVerifierParams() external view returns (VerifierParams memory);

    function isDiamondStorageFrozen() external view returns (bool);

    function getSecurityCouncil() external view returns (address);

    function getUpgradeProposalState() external view returns (UpgradeState);

    function getProposedUpgradeHash() external view returns (bytes32);

    function getProposedUpgradeTimestamp() external view returns (uint256);

    function getCurrentProposalId() external view returns (uint256);

    function isApprovedBySecurityCouncil() external view returns (bool);

    function getPriorityTxMaxGasLimit() external view returns (uint256);

    function getAllowList() external view returns (address);

    function isEthWithdrawalFinalized(uint256 _l2BlockNumber, uint256 _l2MessageIndex) external view returns (bool);

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
