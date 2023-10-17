// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {BridgehubChain} from "../../../../../cache/solpp-generated-contracts/bridgehub/BridgehubChain.sol";

contract BridgehubChainTest is Test {
    BridgehubChain internal bridgehubChain;

    uint256 internal chainId;
    address internal stateTransition;
    address internal governor;
    IAllowList internal allowList;
    uint256 internal priorityTxMaxGasLimit;
}
