// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract Callable {
    event Called(uint256 value, bytes data);

    fallback() external payable {
        uint256 len;
        assembly {
            len := calldatasize()
        }
        bytes memory data = new bytes(len);
        assembly {
            calldatacopy(add(data, 0x20), 0, len)
        }
        emit Called(msg.value, data);
    }
}
