// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract DummyUpgrade {
    event Upgraded();

    function performUpgrade() public {
        emit Upgraded();
    }
}
