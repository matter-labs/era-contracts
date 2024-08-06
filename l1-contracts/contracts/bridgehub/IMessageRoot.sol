// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "./IBridgehub.sol";

interface IMessageRoot {
    function BRIDGE_HUB() external view returns (IBridgehub);

    function addNewChain(uint256 _chainId) external;

    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) external;

    function addNewChainIfNeeded(uint256 _chainId) external;
}
