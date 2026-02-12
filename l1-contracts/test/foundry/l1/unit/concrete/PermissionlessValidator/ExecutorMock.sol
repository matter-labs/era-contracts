// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract ExecutorMock {
    address public commitChainAddress;
    uint256 public commitProcessFrom;
    uint256 public commitProcessTo;
    bytes public commitData;

    address public proveChainAddress;
    uint256 public proveProcessFrom;
    uint256 public proveProcessTo;
    bytes public proveData;

    address public executeChainAddress;
    uint256 public executeProcessFrom;
    uint256 public executeProcessTo;
    bytes public executeData;

    uint8 public callIndex;

    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) external {
        require(_chainAddress == address(this), "chain mismatch");
        require(callIndex == 0, "commit order");

        callIndex = 1;
        commitChainAddress = _chainAddress;
        commitProcessFrom = _processFrom;
        commitProcessTo = _processTo;
        commitData = _commitData;
    }

    function proveBatchesSharedBridge(
        address _chainAddress,
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _proveData
    ) external {
        require(_chainAddress == address(this), "chain mismatch");
        require(callIndex == 1, "prove order");

        callIndex = 2;
        proveChainAddress = _chainAddress;
        proveProcessFrom = _processFrom;
        proveProcessTo = _processTo;
        proveData = _proveData;
    }

    function executeBatchesSharedBridge(
        address _chainAddress,
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _executeData
    ) external {
        require(_chainAddress == address(this), "chain mismatch");
        require(callIndex == 2, "execute order");

        callIndex = 3;
        executeChainAddress = _chainAddress;
        executeProcessFrom = _processFrom;
        executeProcessTo = _processTo;
        executeData = _executeData;
    }
}
