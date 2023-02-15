// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IExecutor.sol";

interface IMockExecutor {
    function fakeProveBlocks(
        IExecutor.StoredBlockInfo calldata _prevBlock,
        IExecutor.StoredBlockInfo[] calldata _committedBlocks,
        IExecutor.ProofInput calldata _proof
    ) external;
}
