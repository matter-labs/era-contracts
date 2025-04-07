// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IAccount.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, NONCE_HOLDER_SYSTEM_CONTRACT, L2_INTEROP_HANDLER, L2_MESSAGE_VERIFICATION, INonceHolder} from "./Constants.sol";
import {MessageInclusionProof, L2Message} from "./libraries/Messaging.sol";
import {TransactionHelper, Transaction} from "./libraries/TransactionHelper.sol";
import {FailedToPayOperator} from "./SystemContractErrors.sol";
import {InteropTrigger, GasFields, TRIGGER_IDENTIFIER} from "./libraries/Messaging.sol";
import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";

error MessageNotIncluded();
event MessageNotIncluded2();

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The account that is deployed for interop.
 * @dev The bytecode of the contract is set by default for all addresses for which no other bytecodes are deployed.
 * @notice If the caller is not a bootloader or interop handler always returns empty data on call, just like EOA does.
 * @notice If it is delegate called always returns empty data, just like EOA does.
 */
contract StandardTriggerAccount is IAccount {
    using TransactionHelper for *;

    /**
     * @dev Simulate the behavior of the EOA if the caller is not the bootloader.
     * Essentially, for all non-bootloader callers halt the execution with empty return data.
     * If all functions will use this modifier AND the contract will implement an empty payable fallback()
     * then the contract will be indistinguishable from the EOA when called.
     */
    modifier ignoreNonBootloader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            // If function was called outside of the bootloader, behave like an EOA.
            assembly {
                return(0, 0)
            }
        }
        // Continue execution if called from the bootloader.
        _;
    }

    /**
     * @dev Simulate the behavior of the EOA if it is called via `delegatecall`.
     * Thus, the default account on a delegate call behaves the same as EOA on Ethereum.
     * If all functions will use this modifier AND the contract will implement an empty payable fallback()
     * then the contract will be indistinguishable from the EOA when called.
     */
    modifier ignoreInDelegateCall() {
        address codeAddress = SystemContractHelper.getCodeAddress();
        if (codeAddress != address(this)) {
            // If the function was delegate called, behave like an EOA.
            assembly {
                return(0, 0)
            }
        }

        // Continue execution if not delegate called.
        _;
    }

    function executeTransaction(
        bytes32, // _txHash
        bytes32, // _suggestedSignedHash
        Transaction calldata _transaction
    ) external payable virtual override ignoreNonBootloader ignoreInDelegateCall {
        address to = address(uint160(_transaction.to));
        if (to == (address((L2_INTEROP_HANDLER)))) {
            (bytes memory executionBundle, bytes memory executionProof) = abi.decode(_transaction.data, (bytes, bytes));
            MessageInclusionProof memory executionInclusionProof = abi.decode(executionProof, (MessageInclusionProof));
            L2_INTEROP_HANDLER.executeBundle(executionBundle, executionInclusionProof, false);
            return;
        }

        // super._execute(_transaction);
    }

    function payForTransaction(
        bytes32 _txHash,
        bytes32 _suggestedSignedHash,
        Transaction calldata _transaction
    ) external payable ignoreNonBootloader ignoreInDelegateCall {
        if (_transaction.to == uint256(uint160(address(L2_INTEROP_HANDLER)))) {
            (bytes memory paymasterBundle, bytes memory paymasterProof, , , ) = abi.decode(
                _transaction.signature,
                (bytes, bytes, address, address, bytes)
            );
            MessageInclusionProof memory paymasterInclusionProof = abi.decode(paymasterProof, (MessageInclusionProof));
            L2_INTEROP_HANDLER.executeBundle(paymasterBundle, paymasterInclusionProof, true);
        }
        bool success = _transaction.payToTheBootloader();
        if (!success) {
            revert FailedToPayOperator();
        }
    }

    function validateTransaction(
        bytes32, // _txHash
        bytes32 _suggestedSignedHash,
        Transaction calldata _transaction
    ) external payable override ignoreNonBootloader ignoreInDelegateCall returns (bytes4 magic) {
        SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(NONCE_HOLDER_SYSTEM_CONTRACT),
            0,
            abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (_transaction.nonce))
        );
        if (_transaction.to == uint256(uint160(address(L2_INTEROP_HANDLER)))) {
            (bytes memory executionBundle, ) = abi.decode(_transaction.data, (bytes, bytes));
            (
                bytes memory paymasterBundle,
                ,
                address sender,
                address refundRecipient,
                bytes memory triggerProofBytes
            ) = abi.decode(_transaction.signature, (bytes, bytes, address, address, bytes));
            MessageInclusionProof memory triggerProof = abi.decode(triggerProofBytes, (MessageInclusionProof));
            InteropTrigger memory interopTrigger = InteropTrigger({
                sender: address(uint160(sender)),
                recipient: address(this),
                destinationChainId: block.chainid,
                feeBundleHash: keccak256(paymasterBundle),
                executionBundleHash: keccak256(executionBundle),
                gasFields: GasFields({
                    gasLimit: _transaction.gasLimit,
                    gasPerPubdataByteLimit: _transaction.gasPerPubdataByteLimit,
                    refundRecipient: refundRecipient,
                    paymaster: address(0),
                    paymasterInput: ""
                })
            });
            triggerProof.message.data = bytes.concat(TRIGGER_IDENTIFIER, abi.encode(interopTrigger));
            bool isIncluded = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
                triggerProof.chainId,
                triggerProof.l1BatchNumber,
                triggerProof.l2MessageIndex,
                triggerProof.message,
                triggerProof.proof
            );
            if (!isIncluded) {
                revert MessageNotIncluded();
            }
            return ACCOUNT_VALIDATION_SUCCESS_MAGIC;
        }

        // magic = super._validateTransaction(_suggestedSignedHash, _transaction);
    }

    function prepareForPaymaster(
        bytes32, // _txHash
        bytes32, // _suggestedSignedHash
        Transaction calldata _transaction
    ) external payable ignoreNonBootloader ignoreInDelegateCall {
        _transaction.processPaymasterInput();
    }

    function executeTransactionFromOutside(Transaction calldata _transaction) external payable override {
        // Behave the same as for fallback/receive, just execute nothing, returns nothing
    }

    receive() external payable {
        // If the contract is called directly, behave like an EOA
    }
}
