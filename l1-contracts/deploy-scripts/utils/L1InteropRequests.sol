// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL1InteropCenter} from "contracts/interop/IL1InteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

struct L1L2MessageParams {
    uint256 chainId;
    uint256 mintValue;
    address l2Contract;
    uint256 l2Value;
    bytes l2Calldata;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    bytes[] factoryDeps;
    address refundRecipient;
}

struct L1L2IndirectMessageParams {
    uint256 chainId;
    uint256 mintValue;
    uint256 l2Value;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
    address crossChainSender;
    uint256 indirectCallValue;
    bytes indirectCallData;
}

library L1InteropRequests {
    function encodeDirect(
        L1L2MessageParams memory _request
    ) internal pure returns (bytes memory recipient, bytes memory payload, bytes[] memory attributes) {
        attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (_request.mintValue, _request.l2GasLimit, _request.l2GasPerPubdataByteLimit, _request.refundRecipient)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_request.l2Value));
        attributes[2] = abi.encodeCall(IERC7786Attributes.factoryDeps, (_request.factoryDeps));
        return (
            InteroperableAddress.formatEvmV1(_request.chainId, _request.l2Contract),
            _request.l2Calldata,
            attributes
        );
    }

    function encodeIndirect(
        L1L2IndirectMessageParams memory _request
    ) internal pure returns (bytes memory recipient, bytes memory payload, bytes[] memory attributes) {
        attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (_request.mintValue, _request.l2GasLimit, _request.l2GasPerPubdataByteLimit, _request.refundRecipient)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_request.l2Value));
        attributes[2] = abi.encodeCall(IERC7786Attributes.indirectCall, (_request.indirectCallValue));
        return (
            InteroperableAddress.formatEvmV1(_request.chainId, _request.crossChainSender),
            _request.indirectCallData,
            attributes
        );
    }

    function encodeDirectCalldata(L1L2MessageParams memory _request) internal pure returns (bytes memory) {
        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = encodeDirect(_request);
        return abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, payload, attributes));
    }

    function encodeIndirectCalldata(L1L2IndirectMessageParams memory _request) internal pure returns (bytes memory) {
        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = encodeIndirect(_request);
        return abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, payload, attributes));
    }

    function requestDirect(
        IL1InteropCenter _center,
        uint256 _value,
        L1L2MessageParams memory _request
    ) internal returns (bytes32) {
        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = encodeDirect(_request);
        return _center.sendMessage{value: _value}(recipient, payload, attributes);
    }

    function requestIndirect(
        IL1InteropCenter _center,
        uint256 _value,
        L1L2IndirectMessageParams memory _request
    ) internal returns (bytes32) {
        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = encodeIndirect(_request);
        return _center.sendMessage{value: _value}(recipient, payload, attributes);
    }
}
