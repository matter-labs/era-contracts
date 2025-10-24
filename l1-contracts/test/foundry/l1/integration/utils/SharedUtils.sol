// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_START, PAUSE_DEPOSITS_TIME_WINDOW_END, CHAIN_MIGRATION_TIME_WINDOW_START, CHAIN_MIGRATION_TIME_WINDOW_END} from "contracts/common/Config.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {GW_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract SharedUtils is Test {
    function clearPriorityQueue(address _bridgehub, uint256 _chainId) public {
        IZKChain chain = IZKChain(IBridgehubBase(_bridgehub).getZKChain(_chainId));
        uint256 treeSize = chain.getPriorityQueueSize();
        // The priorityTree sits at slot 51 of ZKChainStorage
        // unprocessedIndex is the second field (51 + 1 = 52) in PriorityTree.Tree
        bytes32 slot = bytes32(uint256(52));
        uint256 value = uint256(vm.load(address(chain), slot));
        // We modify the unprocessedIndex so that the tree size is zero
        vm.store(address(chain), slot, bytes32(value + treeSize));
    }
}
