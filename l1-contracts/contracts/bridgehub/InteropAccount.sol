// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract InteropAccount {
    event Hello(uint256 indexed);
    event ReturnMessage(bytes indexed error);
    function hello() external payable {
        emit Hello(17);
    }

    function forwardFromIC(address _to, bytes memory _data) external payable {
        emit Hello(18);
        // IC mints value here manually.
        emit Hello(address(this).balance);
        (bool success, bytes memory returnData) = _to.call{value: msg.value}(_data); //
        if (!success) {
            emit ReturnMessage(returnData);
            // revert("Forwarding call failed");
        }
    }

    function deployed() public returns (bool) {
        return true;
    }
}
