// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IBridgeheadBase.sol";
import "../../common/Messaging.sol";

interface IBridgeheadForProof is IBridgeheadBase {
    /// @notice Reading first tx
    function getFirstUnprocessedPriorityTx(uint256 _chainId) external view returns (uint256);

    /// @notice Removing txs from the priority queue
    function collectOperationsFromPriorityQueue(uint256 _chainId, uint256 _index) external returns (bytes32 concatHash);

    /// @notice Adding txs to the priority queue
    function addL2Logs(
        uint256 _chainId,
        uint256 _index,
        bytes32 _l2LogsRootHashes
    ) external;

    function requestL2TransactionProof(
        uint256 _chainId,
        WritePriorityOpParams memory _params,
        bytes calldata _calldata,
        bytes[] calldata _factoryDeps,
        bool _isFree
    ) external returns (bytes32 canonicalTxHash);

    function getGovernor(uint256 _chainId) external view returns (address);

    function newProofSystem(address _proofSystem) external;
}
