// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {L2InteropHandler} from "../../interop/interop-handler/L2InteropHandler.sol";
import {L2Message, MessageInclusionProof} from "../../common/Messaging.sol";
import {AtomicFinalityProof} from "../../atomic-interop/IAtomicInterop.sol";
import {GasFields, InteropTrigger, TRIGGER_IDENTIFIER} from "./Utils.sol";
import {L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_VERIFICATION} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {Transaction} from "../../common/l2-helpers/L2ContractHelper.sol";

L2InteropHandler constant L2_INTEROP_HANDLER = L2InteropHandler(L2_INTEROP_HANDLER_ADDR);

event MessageNotIncluded2();

contract DummyL2StandardTriggerAccount {
    function process(Transaction calldata _transaction) external returns (bool success) {
        /// trigger verification
        {
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
                emit MessageNotIncluded2();
            }
        }

        /// paymaster bundle
        {
            (bytes memory paymasterBundle, bytes memory paymasterProof, , , ) = abi.decode(
                _transaction.signature,
                (bytes, bytes, address, address, bytes)
            );
            AtomicFinalityProof memory paymasterFinality = abi.decode(paymasterProof, (AtomicFinalityProof));
            L2_INTEROP_HANDLER.executeBundle(paymasterBundle, paymasterFinality);
        }

        /// execution bundle
        {
            (bytes memory executionBundle, bytes memory executionProof) = abi.decode(_transaction.data, (bytes, bytes));
            AtomicFinalityProof memory executionFinality = abi.decode(executionProof, (AtomicFinalityProof));
            L2_INTEROP_HANDLER.executeBundle(executionBundle, executionFinality);
        }
        return true;
    }

    receive() external payable {
        // If the contract is called directly, behave like an EOA
    }
}
