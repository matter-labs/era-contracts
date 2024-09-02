// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ConstructorForwarderFailed} from "./L1DevContractsErrors.sol";

contract ConstructorForwarder {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor(address to, bytes memory data) payable {
        (bool success, ) = payable(to).call{value: msg.value}(data);
        if (!success) {
            revert ConstructorForwarderFailed();
        }
    }
}
