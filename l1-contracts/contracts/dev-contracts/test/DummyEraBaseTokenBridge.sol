// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyEraBaseTokenBridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address _prevMsgSender,
        address _l1Token,
        uint256 _amount
    ) external payable {}
}
