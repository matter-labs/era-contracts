// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestDirect, IBridgehub} from "../bridgehub/Bridgehub.sol";

/// @title Remote Governance contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IRemoteGovernance {
    function GOVERNANCE() external view returns (address);

    function BRIDGEHUB() external view returns (IBridgehub);

    function requestL2TransactionDirect(L2TransactionRequestDirect memory _request) external payable;
}
