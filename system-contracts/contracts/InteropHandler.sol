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
event Bytes32(bytes32 data);
event Number(uint256 indexed number);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    address public constant L2_INTEROP_HANDLER = address(INTEROP_HANDLER_SYSTEM_CONTRACT);
    address public constant L2_BASE_TOKEN = address(BASE_TOKEN_SYSTEM_CONTRACT);

    uint256 public feeCounter;
    uint256 public interopCounter;

    function executePaymasterBundle(Transaction calldata _transaction) external {
        feeCounter++;
        (bytes memory paymasterBundle, ) = abi.decode(_transaction.data, (bytes, bytes));
        // (, bytes memory paymasterProof) = abi.decode(_transaction.signature);
        // // todo verify signature = merkleProof.
        InteropBundle memory interopBundle = abi.decode(paymasterBundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        // require(interopCall.to == address(BASE_TOKEN_SYSTEM_CONTRACT), "InteropHandler: Invalid interop call");
        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(msg.sender, baseTokenCall.value);
        // require(msg.sender == baseTokenCall.from, "InteropHandler: Invalid sender"); // todo add aliasing here.
        // require(success, "InteropHandler: Interop call failed");

        // executeInteropBundle(paymasterBundle, paymasterProof)
        // emit PaymasterBundleExecuted(baseTokenCall.to);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(msg.sender, baseTokenCall.value);
    }

    function executeInteropBundle(Transaction calldata _transaction) external {
        interopCounter++;
        // todo verify signature.
        (, bytes memory executionBundle) = abi.decode(_transaction.data, (bytes, bytes));
        // // (bytes memory executionBundle, ) = abi.decode(_transaction.data, (bytes, bytes));

        // bytes memory actualBytes = abi.decode(executionBundle, (bytes));
        InteropBundle memory interopBundle = abi.decode(executionBundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), 1234);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);

        InteropCall memory interopCall = interopBundle.calls[1];        
        bytes memory returnData = this.mimicCall(
            gasleft(),
            interopCall.to,
            interopCall.data,
            interopCall.from,
            false,
            false
        );
    }

    function printBytes(bytes calldata _bytes) public  {
        for (uint256 i = 0; i < _bytes.length; i += 32) {
            bytes memory bytes_0 = _bytes[i:i+32];
            bytes32 bytes32_0 = bytes32(bytes_0);
            // emit Number(i);
            // emit Bytes32(bytes32_0);
        }
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
