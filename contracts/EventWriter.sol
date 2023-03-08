// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {SystemContractHelper, ISystemContract} from "./libraries/SystemContractHelper.sol";
import "./Constants.sol";

/**
 * @author Matter Labs
 * @notice The contract responsible for decoding and writing events using low-level instructions.
 * @dev The metadata and topics are passed via registers, and the first accessible register contains their number.
 * The rest of the data is passed via calldata without copying.
 */
contract EventWriter is ISystemContract {
    fallback(bytes calldata _data) external onlySystemCall returns(bytes memory _result) {
        uint256 numberOfTopics = SystemContractHelper.getExtraAbiData(0);
        require(numberOfTopics <= 4, "Only 4 indexed fields are allowed");

        uint256 dataLength = _data.length;
        // Increment to include the msg.sender as a topic
        uint256 initializer = (dataLength << 32) + (numberOfTopics + 1);

        SystemContractHelper.eventInitialize(initializer, uint256(uint160(msg.sender)));
        // Early return if the event is empty
        if (initializer == 1) {
            return _result;
        }

        uint256 topicIndex;
        uint256 dataCursor = 0;

        // Write topics by two at a time
        for (topicIndex = 0; (numberOfTopics - topicIndex) >= 2; topicIndex += 2) {
            uint256 topic1 = SystemContractHelper.getExtraAbiData(topicIndex + 1);
            uint256 topic2 = SystemContractHelper.getExtraAbiData(topicIndex + 2);
            SystemContractHelper.eventWrite(topic1, topic2);
        }

        // If the number of topics is odd, the last one is written with the first data chunk or zero
        if (numberOfTopics % 2 == 1) {
            uint256 remainingTopic = SystemContractHelper.getExtraAbiData(numberOfTopics);
            uint256 firstChunk;
            assembly {
                firstChunk := calldataload(0)
            }
            SystemContractHelper.eventWrite(remainingTopic, firstChunk);
            dataCursor += 0x20;
        }

        // Write data chunks by two at a time. The last one can be beyond the calldata and is expected to be zero
        for (; dataCursor < dataLength; dataCursor += 0x40) {
            uint256 chunk1;
            uint256 chunk2;
            assembly {
                chunk1 := calldataload(dataCursor)
                chunk2 := calldataload(add(dataCursor, 0x20))
            }
            SystemContractHelper.eventWrite(chunk1, chunk2);
        }
    }
}
