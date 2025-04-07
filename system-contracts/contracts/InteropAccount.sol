// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2_INTEROP_HANDLER} from "./Constants.sol";
import {MessageInclusionProof, L2Message} from "./libraries/Messaging.sol";
import {DefaultAccount} from "./DefaultAccount.sol";
import {TransactionHelper, Transaction} from "./libraries/TransactionHelper.sol";

event ReturnMessage(bytes indexed error);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The account that is deployed for interop.
 * @dev The bytecode of the contract is set by default for all addresses for which no other bytecodes are deployed.
 * @notice If the caller is not a bootloader or interop handler always returns empty data on call, just like EOA does.
 * @notice If it is delegate called always returns empty data, just like EOA does.
 */
contract InteropAccount is DefaultAccount {
    address immutable VERIFICATION_ADDRESS;

    constructor(address _verificationAddress) {
        VERIFICATION_ADDRESS = _verificationAddress;
    }

    function forwardFromIC(address _to, uint256 _value, bytes memory _data) external payable {
        // IC mints value here manually.
        (bool success, bytes memory returnData) = _to.call{value: _value}(_data); //
        if (!success) {
            emit ReturnMessage(returnData);
            revert("Forwarding call failed");
        }
    }

    function _getVerificationAddress() internal view override returns (address) {
        return VERIFICATION_ADDRESS;
    }
}
