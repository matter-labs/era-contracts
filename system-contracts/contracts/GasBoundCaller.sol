// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {EfficientCall} from "./libraries/EfficientCall.sol";
import {REAL_SYSTEM_CONTEXT_CONTRACT} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that allows to limit the final gas expenditure of the call.
 * @dev This contract MUST be deployed in the *user space*. It does not need any functionality that only
 * system contracts have and it can relay call to any contract, breaking potential trust in system contracts.
 */
contract GasBoundCaller {
    /// @notice We assume that no more than `CALL_ENTRY_OVERHEAD` ergs are used for the O(1) operations at the start
    /// of execution of the contract, such as abi decoding the parameters, jumping to the correct function, etc.
    uint256 constant CALL_ENTRY_OVERHEAD = 800;
    /// @notice We assume that no more than `CALL_RETURN_OVERHEAD` ergs are used for the O(1) operations at the end of the execution,
    /// as such relaying the return.
    uint256 constant CALL_RETURN_OVERHEAD = 200;

    /// @notice The function that implements limiting of the total gas expenditure of the call.
    /// @dev On Era, the gas for pubdata is charged at the end of the execution of the entire transaction, meaning
    /// that if a subcall is not trusted, it can consume lots of pubdata in the process. This function ensures that
    /// no more than  `_maxTotalGas` will be allowed to be spent by the call. To be sure, this function uses some margin
    /// (`BOUND_CALL_OVERHEAD`) to ensure that the call will not exceed the limit, so it may actually spend a bit less than
    /// `_maxTotalGas` in the end.
    /// @dev The entire `gas` passed to this function could be used, regardless
    /// of the `_maxTotalGas` parameter. In other words, `max(gas(), _maxTotalGas)` is the maximum amount of gas that can be spent by this function.
    /// @dev The function relays the `returndata` returned by the callee. In case the `callee` reverts, it reverts with the same error.
    /// @param _to The address of the contract to call.
    /// @param _maxTotalGas The maximum amount of gas that can be spent by the call.
    /// @param _data The calldata for the call.
    function gasBoundCall(address _to, uint256 _maxTotalGas, bytes calldata _data) external payable {
        // At the start of the execution we deduce how much gas be spent on things that will be
        // paid for later on by the transaction.
        // The `expectedForCompute` variable is an upper bound of how much this contract can spend on compute and
        // MUST be higher or equal to the `gas` passed into the call.
        uint256 expectedForCompute = gasleft() + CALL_ENTRY_OVERHEAD;

        // We expect that the `_maxTotalGas` at least includes the `gas` required for the call.
        // This require is more of a safety protection for the users that call this function with incorrect parameters.
        //
        // Ultimately, the entire `gas` sent to this call can be spent on compute regardless of the `_maxTotalGas` parameter.
        require(_maxTotalGas >= gasleft(), "Gas limit is too low");

        // This is the amount of gas that can be spent *exclusively* on pubdata in addition to the `gas` provided to this function.
        uint256 pubdataAllowance = _maxTotalGas > expectedForCompute ? _maxTotalGas - expectedForCompute : 0;

        uint256 pubdataPublishedBefore = REAL_SYSTEM_CONTEXT_CONTRACT.getCurrentPubdataSpent();

        // We never permit system contract calls.
        // If the call fails, the `EfficientCall.call` will propagate the revert.
        // Since the revert is propagated, the pubdata published wouldn't change and so no
        // other checks are needed.
        bytes memory returnData = EfficientCall.call({
            _gas: gasleft(),
            _address: _to,
            _value: msg.value,
            _data: _data,
            _isSystem: false
        });

        uint256 pubdataPublishedAfter = REAL_SYSTEM_CONTEXT_CONTRACT.getCurrentPubdataSpent();

        // It is possible that pubdataPublishedAfter < pubdataPublishedBefore if the call, e.g. removes
        // some of the previously created state diffs
        uint256 pubdataSpent = pubdataPublishedAfter > pubdataPublishedBefore
            ? pubdataPublishedAfter - pubdataPublishedBefore
            : 0;

        uint256 pubdataPrice = REAL_SYSTEM_CONTEXT_CONTRACT.gasPerPubdataByte();

        // In case there is an overflow here, the `_maxTotalGas` wouldbn't be able to cover it anyway, so
        // we don't mind the contract panicking here in case of it.
        uint256 pubdataCost = pubdataPrice * pubdataSpent;

        if (pubdataCost != 0) {
            // Here we double check that the additional cost is not higher than the maximum allowed.
            // Note, that the `gasleft()` can be spent on pubdata too.
            require(pubdataAllowance + gasleft() >= pubdataCost + CALL_RETURN_OVERHEAD, "Not enough gas for pubdata");
        }

        assembly {
            // We just relay the return data from the call.
            return(add(returnData, 0x20), mload(returnData))
        }
    }
}
