// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma abicoder v2;

import {SYSTEM_CONTRACTS_OFFSET} from "./L2ContractHelper.sol";

interface IL2Messenger {
    function sendToL1(bytes memory _message) external returns (bytes32);
}

contract PubdataGenerator {
    IL2Messenger constant L2_MESSENGER = IL2Messenger(address(SYSTEM_CONTRACTS_OFFSET + 0x08));

    function generateNBytes(uint n) internal returns (bytes memory) {
        bytes memory data = new bytes(n);
        for (uint i = 0; i < n; i++) {
            data[i] = bytes1(uint8(i % 256));
        }
        return data;
    } 

    function generate(uint _size) public {
        unchecked {
            // 4 bytes used to encode the length of the message
            // L2_TO_L1_LOG_SERIALIZE_SIZE bytes used to encode L2ToL1Log => 88
            uint size = _size - 4 - 88;
            L2_MESSENGER.sendToL1(generateNBytes(size));
        }
    }
}
