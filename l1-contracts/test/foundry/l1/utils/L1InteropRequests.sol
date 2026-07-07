// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2TransactionRequestDirect, L2TransactionRequestIndirect} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IL1InteropCenter} from "contracts/interop/IL1InteropCenter.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

/// @notice Test helper translating the former `L1Bridgehub.requestL2TransactionDirect` /
/// `requestL2TransactionTwoBridges` request structs into the L1InteropCenter ERC-7786
/// `sendMessage` entry point.
/// @dev Each `request*` helper performs exactly ONE external call (the `sendMessage` itself),
/// so it is safe to use directly after a single `vm.prank`.
library L1InteropRequests {
    /// @dev Encodes the `sendMessage` arguments for a direct (former `requestL2TransactionDirect`) request.
    function encodeDirect(
        L2TransactionRequestDirect memory _request
    ) internal pure returns (bytes memory recipient, bytes memory payload, bytes[] memory attributes) {
        recipient = InteroperableAddress.formatEvmV1(_request.chainId, _request.l2Contract);
        payload = _request.l2Calldata;
        attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (_request.mintValue, _request.l2GasLimit, _request.l2GasPerPubdataByteLimit, _request.refundRecipient)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_request.l2Value));
        attributes[2] = abi.encodeCall(IERC7786Attributes.factoryDeps, (_request.factoryDeps));
    }

    /// @dev Encodes the `sendMessage` arguments for an indirect (former `requestL2TransactionTwoBridges`) request.
    function encodeIndirect(
        L2TransactionRequestIndirect memory _request
    ) internal pure returns (bytes memory recipient, bytes memory payload, bytes[] memory attributes) {
        recipient = InteroperableAddress.formatEvmV1(_request.chainId, _request.secondBridgeAddress);
        payload = _request.secondBridgeCalldata;
        attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (_request.mintValue, _request.l2GasLimit, _request.l2GasPerPubdataByteLimit, _request.refundRecipient)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_request.l2Value));
        attributes[2] = abi.encodeCall(IERC7786Attributes.indirectCall, (_request.secondBridgeValue));
    }

    /// @dev The `sendMessage` equivalent of the former `L1Bridgehub.requestL2TransactionDirect`.
    function requestDirect(
        IL1InteropCenter _interopCenter,
        uint256 _value,
        L2TransactionRequestDirect memory _request
    ) internal returns (bytes32 canonicalTxHash) {
        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = encodeDirect(_request);
        canonicalTxHash = _interopCenter.sendMessage{value: _value}(recipient, payload, attributes);
    }

    /// @dev The `sendMessage` equivalent of the former `L1Bridgehub.requestL2TransactionTwoBridges`.
    function requestIndirect(
        IL1InteropCenter _interopCenter,
        uint256 _value,
        L2TransactionRequestIndirect memory _request
    ) internal returns (bytes32 canonicalTxHash) {
        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = encodeIndirect(_request);
        canonicalTxHash = _interopCenter.sendMessage{value: _value}(recipient, payload, attributes);
    }
}
