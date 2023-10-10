// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IChainBase.sol";

interface IChainExecutor is IChainBase {
    function executeBlocks() external;
}
