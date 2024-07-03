// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "./IBridgehub.sol";

interface IMessageRootAggregator {
    function BRIDGE_HUB() external view returns (IBridgehub);

    function addNewChain(uint256 _chainId) external;

    function chainMessageRoot(uint256 _chainId) external view returns (bytes32);

    function addChainBatchRoot(uint256 _chainId, bytes32 _chainBatchRoot) external;
}
