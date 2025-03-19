// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {TransactionFailed, NotEnoughGas, TooMuchGas} from "contracts/SystemContractErrors.sol";

contract TransferTest {
    function transfer(address payable to, uint256 amount, bool warmUpRecipient) public payable {
        if (warmUpRecipient) {
            // This will warm up both the `X` variable and the balance of the recipient
            TransferTestReentrantRecipient(to).setX{value: msg.value}();
        }

        to.transfer(amount);
    }

    function send(address payable to, uint256 amount, bool warmUpRecipient) public payable {
        if (warmUpRecipient) {
            // This will warm up both the `X` variable and the balance of the recipient
            TransferTestReentrantRecipient(to).setX{value: msg.value}();
        }

        bool success = to.send(amount);

        if (!success) {
            revert TransactionFailed();
        }
    }

    receive() external payable {}
}

contract TransferTestRecipient {
    event Received(address indexed sender, uint256 amount);

    receive() external payable {
        if (gasleft() < 2100) {
            revert NotEnoughGas();
        }
        if (gasleft() > 2300) {
            revert TooMuchGas();
        }
        emit Received(msg.sender, msg.value);
    }
}

contract TransferTestReentrantRecipient {
    uint256 x;

    event Received(uint256 tmp, uint256 amount);

    function setX() external payable {
        x = 1;
    }

    receive() external payable {
        x = 1;
    }
}
