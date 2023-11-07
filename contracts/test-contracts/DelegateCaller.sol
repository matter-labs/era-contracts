// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract DelegateCaller {
    function delegateCall(address _to) external payable {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), _to, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}
