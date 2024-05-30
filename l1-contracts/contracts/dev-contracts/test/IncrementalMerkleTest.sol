// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DynamicIncrementalMerkle} from "../../common/libraries/openzeppelin/IncrementalMerkle.sol";

contract IncrementalMerkleTest {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    DynamicIncrementalMerkle.Bytes32PushTree internal tree;

    constructor(bytes32 zero) {
        tree.setup(zero);
    }

    function push(bytes32 _item) external {
        tree.push(_item);
    }

    function root() external view returns (bytes32) {
        return tree.root();
    }

    function height() external view returns (uint256) {
        return tree.height();
    }

    function index() external view returns (uint256) {
        return tree.nextLeafIndex();
    }

    function side(uint256 _index) external view returns (bytes32) {
        return tree.side(_index);
    }

    function zeros(uint256 _index) external view returns (bytes32) {
        return tree.zeros(_index);
    }
}
