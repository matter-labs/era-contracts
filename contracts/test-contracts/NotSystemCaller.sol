// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract NotSystemCaller {
    address immutable to;

    constructor(address _to) {
        to = _to;
    }

    fallback() external payable {
        address _to = to;
        assembly {
            calldatacopy(0, 0, calldatasize())

            let result := call(gas(), _to, callvalue(), 0, calldatasize(), 0, 0)

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
