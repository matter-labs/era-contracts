// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract DummyMailbox is IMailbox {
    address internal baseTokenBridge;
    uint256 public constant ERA_CHAIN_ID = 9;

    constructor(address _baseTokenBridge) {
        baseTokenBridge = _baseTokenBridge;
    }

    function getName() external view returns (string memory) {
        return "DummyMailbox";
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}

    function proveL2MessageInclusion(
        uint256,
        uint256,
        L2Message calldata,
        bytes32[] calldata
    ) external view returns (bool) {
        return false;
    }

    function proveL2LogInclusion(uint256, uint256, L2Log memory, bytes32[] calldata) external view returns (bool) {
        return false;
    }

    function proveL1ToL2TransactionStatus(
        bytes32,
        uint256,
        uint256,
        uint16,
        bytes32[] calldata,
        TxStatus _status
    ) external view returns (bool) {
        return false;
    }

    function finalizeEthWithdrawal(uint256, uint256, uint16, bytes calldata, bytes32[] calldata) external {}

    function requestL2Transaction(
        address,
        uint256,
        bytes calldata,
        uint256,
        uint256,
        bytes[] calldata,
        address
    ) external payable returns (bytes32 canonicalTxHash) {
        return bytes32(0);
    }

    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata
    ) external returns (bytes32 canonicalTxHash) {
        return bytes32(0);
    }

    function l2TransactionBaseCost(uint256, uint256, uint256) external view returns (uint256) {
        return 0;
    }

    function transferEthToSharedBridge() external {
        uint256 amount = address(this).balance;

        IL1SharedBridge(baseTokenBridge).receiveEth{value: amount}(ERA_CHAIN_ID);
    }
}
