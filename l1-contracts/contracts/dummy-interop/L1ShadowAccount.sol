// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;


import {L2_BRIDGEHUB_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The L1ShadowAccount contract.
contract L1ShadowAccount {

    address public l1InteropHandlerAddress;

    constructor() {
        l1InteropHandlerAddress = msg.sender;
    }

    function executeFromIH(
        address target,
        uint256 value,
        bytes calldata data
    ) external {
        require(msg.sender == l1InteropHandlerAddress, "L1ShadowAccount: not authorized");
        (bool success, ) = target.call{value: value}(data);
        require(success, "L1ShadowAccount: call failed");
    }
}