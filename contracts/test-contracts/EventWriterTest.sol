// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract EventWriterTest {
    event ZeroTopics(bytes data) anonymous;
    event OneTopic(bytes data);
    event TwoTopics(uint256 indexed topic1, bytes data);
    event ThreeTopics(uint256 indexed topic1, uint256 indexed topic2, bytes data);
    event FourTopics(uint256 indexed topic1, uint256 indexed topic2, uint256 indexed topic3, bytes data);

    function zeroTopics(bytes calldata data) external {
        emit ZeroTopics(data);
    }

    function oneTopic(bytes calldata data) external {
        emit OneTopic(data);
    }

    function twoTopics(uint256 topic1, bytes calldata data) external {
        emit TwoTopics(topic1, data);
    }

    function threeTopics(uint256 topic1, uint256 topic2, bytes calldata data) external {
        emit ThreeTopics(topic1, topic2, data);
    }

    function fourTopics(uint256 topic1, uint256 topic2, uint256 topic3, bytes calldata data) external {
        emit FourTopics(topic1, topic2, topic3, data);
    }
}
