// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IAccount.sol";
// import {TransactionHelper, Transaction} from "./libraries/TransactionHelper.sol";
// import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";
// import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {BASE_TOKEN_SYSTEM_CONTRACT} from "./Constants.sol";


import {IInteropHandler, InteropCall} from "./interfaces/IInteropHandler.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    function executePaymasterBundle(Transaction calldata _transaction) external {
        (bytes memory paymasterBundle, ) = abi.decode(_transaction.data);
        // (, bytes memory paymasterProof) = abi.decode(_transaction.signature);
        // todo verify signature.
        InteropCall memory interopCall = abi.decode(paymasterBundle);
        require(interopCall.to == address(BASE_TOKEN_SYSTEM_CONTRACT), "InteropHandler: Invalid interop call");
        (uint256 amount) = abi.decode(paymasterBundle);
        (bool success, ) = BASE_TOKEN_SYSTEM_CONTRACT.mint(msg.sender, amount);
        require(success, "InteropHandler: Interop call failed");

        // executeInteropBundle(paymasterBundle, paymasterProof)
    }

    function executeInteropBundle(Transaction calldata _transaction) external {
        // todo verify signature.
        (, bytes memory executionBundle) = abi.decode(_transaction.data);
        InteropCall memory interopCall = abi.decode(executionBundle);
        bytes memory returnData = EfficientCall.mimicCall(gasleft(), interopCall.to, interopCall.input, interopCall.from, false, false);
    }
}
