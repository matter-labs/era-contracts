// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {BridgeheadChain} from "../../../../../cache/solpp-generated-contracts/bridgehead/BridgeheadChain.sol";

contract BridgeheadChainTest is Test {
    BridgeheadChain internal bridgeheadChain;

    uint256 internal chainId;
    address internal proofSystem;
    address internal governor;
    IAllowList internal allowList;
    uint256 internal priorityTxMaxGasLimit;
}
