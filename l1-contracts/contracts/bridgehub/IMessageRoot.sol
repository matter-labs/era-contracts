// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "./IBridgehub.sol";

interface IMessageRoot {
    function BRIDGE_HUB() external view returns (IBridgehub);

    // function chainMessageRoot(uint256 _chainId) external view returns (bytes32);
}
