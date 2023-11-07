// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract MockERC20Approve {
    event Approved(address to, uint256 value);

    function approve(address spender, uint256 value) external returns (bool) {
        emit Approved(spender, value);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return 0;
    }
}
