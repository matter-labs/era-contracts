// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;


import {L2_BRIDGEHUB_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The L2InteropCenter contract is responsible for sending interops to L1.
contract L2InteropCenter {

    address public l1InteropHandlerAddress;

    /// send bundle to L1
    /// 1. withdraw token to L1 shadow account
    /// 2. deploy shadow account if needed on L1. 
    /// 3+. arbitrary calls from shadow account to arbitrary L1 contracts. 


    function sendTokenWithdrawalAndBundleToL1(
        bytes32 assetId,
        uint256 amount,
        ShadowAccountOp[] memory shadowAccountOps
    ) external {

    }

    function l1ShadowAccount(
        address _l2CallerAddress
    ) returns (address) {
        // get create2 address from l1 interop handler and shadow account bytecode
    }
}