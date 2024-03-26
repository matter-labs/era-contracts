// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyERC20BytesTransferReturnValue {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    bytes returnValue;

    constructor(bytes memory _returnValue) {
        returnValue = _returnValue;
    }

    function transfer(address _recipient, uint256 _amount) external view returns (bytes memory) {
        // Hack to prevent Solidity warnings
        _recipient;
        _amount;

        return returnValue;
    }
}
