// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

contract InteropAccount {
    event ReturnMessage(bytes indexed error);

    function forwardFromIC(address _to, uint256 _value, bytes memory _data) external payable {
        // IC mints value here manually.
        (bool success, bytes memory returnData) = _to.call{value: _value}(_data); //
        if (!success) {
            emit ReturnMessage(returnData);
            // revert("Forwarding call failed");
        }
    }

    function deployed() public returns (bool) {
        return true;
    }

    fallback() external payable {}
}
