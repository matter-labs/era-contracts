// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IAccount.sol";
import {TransactionHelper, Transaction} from "./libraries/TransactionHelper.sol";
// import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";
// import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {BASE_TOKEN_SYSTEM_CONTRACT, INTEROP_HANDLER_SYSTEM_CONTRACT} from "./Constants.sol";

import {IInteropHandler, InteropCall, InteropBundle} from "./interfaces/IInteropHandler.sol";

event PaymasterBundleExecuted(address indexed where);
event DataBytesExecuted(bytes data);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    address public constant L2_INTEROP_HANDLER = address(INTEROP_HANDLER_SYSTEM_CONTRACT);
    address public constant L2_BASE_TOKEN = address(BASE_TOKEN_SYSTEM_CONTRACT);

    function executePaymasterBundle(Transaction calldata _transaction) external {
        (bytes memory paymasterBundle, ) = abi.decode(_transaction.data, (bytes, bytes));
        // (, bytes memory paymasterProof) = abi.decode(_transaction.signature);
        // todo verify signature = merkleProof.
        InteropBundle memory interopBundle = abi.decode(paymasterBundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        // require(interopCall.to == address(BASE_TOKEN_SYSTEM_CONTRACT), "InteropHandler: Invalid interop call");
        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);
        require(msg.sender == baseTokenCall.from, "InteropHandler: Invalid sender"); // todo add aliasing here.
        // require(success, "InteropHandler: Interop call failed");

        // executeInteropBundle(paymasterBundle, paymasterProof)
        emit PaymasterBundleExecuted(baseTokenCall.to);
    }

    function executeInteropBundle(Transaction calldata _transaction) external {
        // todo verify signature.
        (, bytes memory executionBundle) = abi.decode(_transaction.data, (bytes, bytes));
        InteropCall memory interopCall = abi.decode(executionBundle, (InteropCall));
        // emit PaymasterBundleExecuted(interopCall.to);
        // emit DataBytesExecuted(interopCall.data);
        bytes memory finalizeDepositData = abi.encodeWithSignature(
            "finalizeDeposit(uint256,bytes32,bytes)",
            0,
            bytes32(0x00),
            "0x00"
        );
        // bytes memory finalizeDepositData = hex"9c884fd100000000000000000000000000000000000000000000000000000000000001109c0d4add1b94fd348199e854b0efbc68c1ec865016908282cfa32b5c02a69606000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000001a36f9dbffc50cd7c7d5ccec1ce3232d1f08280b0000000000000000000000008da7cffaf1eab3bce2817d0c20ef5cd7ce82455a00000000000000000000000060d16f709e9179f961d5786f8d035e337990971f0000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c1010000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004574254430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000";
        emit DataBytesExecuted(finalizeDepositData);
        bytes memory returnData = this.mimicCall(
            gasleft(),
            interopCall.to,
            finalizeDepositData,
            interopCall.from,
            false,
            false
        );
    }

    function mimicCall(
        uint256 _gas,
        address _address,
        bytes calldata _data,
        address _whoToMimic,
        bool _isConstructor,
        bool _isSystem
    ) external returns (bytes memory returnData) {
        returnData = EfficientCall.mimicCall(gasleft(), _address, _data, _whoToMimic, _isConstructor, _isSystem);
    }
}
