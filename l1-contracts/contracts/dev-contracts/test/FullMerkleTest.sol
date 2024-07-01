// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {FullMerkle} from "../../common/libraries/FullMerkle.sol";

contract FullMerkleTest {
    using FullMerkle for FullMerkle.FullTree;

    FullMerkle.FullTree internal tree;

    constructor(bytes32 zero) {
        tree.setup(zero);
    }

    function pushNewLeaf(bytes32 _item) external {
        tree.pushNewLeaf(_item);
    }

    function updateLeaf(uint256 _index, bytes32 _item) external {
        tree.updateLeaf(_index, _item);
    }

    function updateAllLeaves(bytes32[] memory _items) external {
        tree.updateAllLeaves(_items);
    }

    function updateAllNodesAtHeight(uint256 _height, bytes32[] memory _items) external {
        tree.updateAllNodesAtHeight(_height, _items);
    }

    function root() external view returns (bytes32) {
        return tree.root();
    }

    function height() external view returns (uint256) {
        return tree._height;
    }

    function index() external view returns (uint256) {
        return tree._leafNumber;
    }

    function node(uint256 _height, uint256 _index) external view returns (bytes32) {
        return tree._nodes[_height][_index];
    }

    function nodeCount(uint256 _height) external view returns (uint256) {
        return tree._nodes[_height].length;
    }

    function zeros(uint256 _index) external view returns (bytes32) {
        return tree._zeros[_index];
    }
}
