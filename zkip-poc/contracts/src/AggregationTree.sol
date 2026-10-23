// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AGGREGATED_SMALL_SLOTS,
    AGGREGATION_BASE_DOMAIN,
    AGGREGATION_FOLD_DOMAIN,
    AGGREGATION_FOLD_TOKEN,
    RECURSIVE_AGGREGATION_MAX_HEIGHT
} from "./ZKIPLiteConfig.sol";
import {BadAggregate} from "./ZKIPLiteErrors.sol";

library AggregationTree {
    struct Node {
        bytes32 hash;
        uint256 height;
    }

    function root(bytes32[] calldata _leaves, bytes calldata _shape, uint256 _height) internal pure returns (bytes32) {
        require(_leaves.length != 0 && _height <= RECURSIVE_AGGREGATION_MAX_HEIGHT, BadAggregate());
        Node[] memory stack = new Node[](_shape.length);
        uint256 top;
        uint256 leaf;
        for (uint256 tokenIndex = 0; tokenIndex < _shape.length; ++tokenIndex) {
            uint256 token = uint8(_shape[tokenIndex]);
            if (token == 0) {
                stack[top++] = Node(bytes32(0), 0);
                continue;
            }
            bytes32[AGGREGATED_SMALL_SLOTS] memory children;
            uint256 height;
            bytes32 domain = AGGREGATION_BASE_DOMAIN;
            if (token <= AGGREGATED_SMALL_SLOTS) {
                require(leaf + token <= _leaves.length, BadAggregate());
                for (uint256 i = 0; i < token; ++i) {
                    children[i] = _leaves[leaf++];
                }
            } else {
                require(token == AGGREGATION_FOLD_TOKEN && top >= AGGREGATED_SMALL_SLOTS, BadAggregate());
                top -= AGGREGATED_SMALL_SLOTS;
                for (uint256 i = 0; i < AGGREGATED_SMALL_SLOTS; ++i) {
                    Node memory child = stack[top + i];
                    children[i] = child.hash;
                    if (child.height > height) {
                        height = child.height;
                    }
                }
                ++height;
                require(height <= RECURSIVE_AGGREGATION_MAX_HEIGHT, BadAggregate());
                domain = AGGREGATION_FOLD_DOMAIN;
            }
            stack[top++] = Node(keccak256(abi.encodePacked(domain, children)), height);
        }
        require(top == 1 && leaf == _leaves.length && stack[0].height == _height, BadAggregate());
        return stack[0].hash;
    }
}
