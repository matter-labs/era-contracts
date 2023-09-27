// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../libraries/PriorityQueue.sol";
import "./IBase.sol";

/// @author Matter Labs
/// @dev This interface contains getters for the zkSync contract that should not be used,
/// but still are keot for backward compatibility.
interface ILegacyGetters is IBase {
    function getTotalBlocksCommitted() external view returns (uint256);

    function getTotalBlocksVerified() external view returns (uint256);

    function getTotalBlocksExecuted() external view returns (uint256);

    function storedBlockHash(uint256 _batchNumber) external view returns (bytes32);

    function getL2SystemContractsUpgradeBlockNumber() external view returns (uint256);
}
