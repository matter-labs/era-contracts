// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../libraries/PriorityQueue.sol";
import {VerifierParams, UpgradeState} from "../Storage.sol";
import "./IBase.sol";

interface IGetters is IBase {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    function getVerifier() external view returns (address);

    function getGovernor() external view returns (address);

    function getPendingGovernor() external view returns (address);

    function getTotalBatchesCommitted() external view returns (uint256);

    function getTotalBatchesVerified() external view returns (uint256);

    function getTotalBatchesExecuted() external view returns (uint256);

    function getTotalPriorityTxs() external view returns (uint256);

    function getFirstUnprocessedPriorityTx() external view returns (uint256);

    function getPriorityQueueSize() external view returns (uint256);

    function priorityQueueFrontOperation() external view returns (PriorityOperation memory);

    function isValidator(address _address) external view returns (bool);

    function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32 hash);

    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32);

    function getL2BootloaderBytecodeHash() external view returns (bytes32);

    function getL2DefaultAccountBytecodeHash() external view returns (bytes32);

    function getVerifierParams() external view returns (VerifierParams memory);

    function isDiamondStorageFrozen() external view returns (bool);

    function getProtocolVersion() external view returns (uint256);

    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32);

    function getL2SystemContractsUpgradeBatchNumber() external view returns (uint256);

    function getPriorityTxMaxGasLimit() external view returns (uint256);

    function getAllowList() external view returns (address);

    function isEthWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool);

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
