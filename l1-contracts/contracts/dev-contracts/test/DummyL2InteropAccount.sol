// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;
event ReturnMessage(bytes indexed error);

contract DummyL2InteropAccount {
    function forwardFromIC(address _to, uint256 _value, bytes memory _data) external payable {
        // IC mints value here manually.
        (bool success, bytes memory returnData) = _to.call{value: _value}(_data); //
        if (!success) {
            emit ReturnMessage(returnData);
            revert("Forwarding call failed");
        }
    }
}
