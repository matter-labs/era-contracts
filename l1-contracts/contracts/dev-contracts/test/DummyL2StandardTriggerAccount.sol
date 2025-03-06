// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInteropHandler} from "../../bridgehub/IInteropHandler.sol";
import {InteropCall, InteropBundle, MessageInclusionProof, L2Message} from "../../common/Messaging.sol";
import {L2_INTEROP_HANDLER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

IInteropHandler constant L2_INTEROP_HANDLER = IInteropHandler(L2_INTEROP_HANDLER_ADDR);

contract DummyL2StandardTriggerAccount {
    function process(bytes calldata _data, bytes calldata _signature) external returns (bytes32 hash) {
        (bytes memory paymasterBundle, bytes memory executionBundle) = abi.decode(_data, (bytes, bytes));
        (bytes memory paymasterProof, bytes memory executionProof) = abi.decode(_signature, (bytes, bytes));
        MessageInclusionProof memory paymasterInclusionProof = abi.decode(paymasterProof, (MessageInclusionProof));
        MessageInclusionProof memory executionInclusionProof = abi.decode(executionProof, (MessageInclusionProof));

        L2_INTEROP_HANDLER.executeBundle(paymasterBundle, paymasterInclusionProof, true);
        L2_INTEROP_HANDLER.executeBundle(executionBundle, executionInclusionProof, false);
    }
}
