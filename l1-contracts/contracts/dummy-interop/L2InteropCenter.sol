// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;


import {L2_BRIDGEHUB_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Create2Address} from "./Create2Address.sol";
import {L1ShadowAccount} from "./L1ShadowAccount.sol";

struct ShadowAccountOp {
    address target;
    uint256 value;
    bytes data;
}


/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The L2InteropCenter contract is responsible for sending interops to L1.
contract L2InteropCenter {

    address public l1InteropHandlerAddress;

    bytes32 public shadowAccountBytecodeHash;

    constructor(address _l1InteropHandlerAddress){
        l1InteropHandlerAddress = _l1InteropHandlerAddress;
        shadowAccountBytecodeHash = keccak256(type(L1ShadowAccount).creationCode);
    }

    /// send bundle to L1
    /// 1. withdraw token to L1 shadow account
    /// 2. deploy shadow account if needed on L1. 
    /// 3+. arbitrary calls from shadow account to arbitrary L1 contracts. 


    function sendBundleToL1(
        ShadowAccountOp[] memory shadowAccountOps
    ) external {

        bytes memory data = abi.encode(msg.sender, shadowAccountOps);
        /// low level call as there is an issue with zksync os
        (bool success, ) = address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT).call(abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector, data));
        require(success, "Send bundle to L1 failed");
    }

    function l1ShadowAccount(
        address _l2CallerAddress
    ) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(_l2CallerAddress));
        return Create2Address.getNewAddressCreate2EVM(address(l1InteropHandlerAddress), salt, shadowAccountBytecodeHash);
    }
}