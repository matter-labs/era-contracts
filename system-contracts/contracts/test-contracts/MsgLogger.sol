// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ISystemContract} from "../interfaces/ISystemContract.sol";

contract MsgLogger is ISystemContract {
    event Called(uint256 value, bytes data, bool systemFlag);

    fallback() external payable onlySystemCall {
        emit Called(msg.value, msg.data, true); // will fail if not system call
    }
}
