// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IGovernance} from "../../governance/IGovernance.sol";

contract ReenterGovernance {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    IGovernance governance;

    // Store call, predecessor and salt separately,
    // because Operation struct can't be stored on storage.
    IGovernance.Call call;
    bytes32 predecessor;
    bytes32 salt;

    // Save one value to determine whether reentrancy already happen.
    bool alreadyReentered;

    enum FunctionToCall {
        Unset,
        Execute,
        ExecuteInstant,
        Cancel
    }

    FunctionToCall functionToCall;

    function initialize(
        IGovernance _governance,
        IGovernance.Operation memory _op,
        FunctionToCall _functionToCall
    ) external {
        governance = _governance;
        require(_op.calls.length == 1, "Only 1 calls supported");
        call = _op.calls[0];
        predecessor = _op.predecessor;
        salt = _op.salt;

        functionToCall = _functionToCall;
    }

    fallback() external payable {
        if (!alreadyReentered) {
            alreadyReentered = true;
            IGovernance.Call[] memory calls = new IGovernance.Call[](1);
            calls[0] = call;
            IGovernance.Operation memory op = IGovernance.Operation({
                calls: calls,
                predecessor: predecessor,
                salt: salt
            });

            if (functionToCall == ReenterGovernance.FunctionToCall.Execute) {
                governance.execute(op);
            } else if (functionToCall == ReenterGovernance.FunctionToCall.ExecuteInstant) {
                governance.executeInstant(op);
            } else if (functionToCall == ReenterGovernance.FunctionToCall.Cancel) {
                bytes32 opId = governance.hashOperation(op);
                governance.cancel(opId);
            } else {
                revert("Unset function to call");
            }
        }
    }
}
