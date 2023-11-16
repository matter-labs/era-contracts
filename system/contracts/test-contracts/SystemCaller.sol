// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {SystemContractsCaller} from "../libraries/SystemContractsCaller.sol";

contract SystemCaller {
    address immutable to;

    constructor(address _to) {
        to = _to;
    }

    fallback() external payable {
        bytes memory result = SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            to,
            uint128(msg.value),
            msg.data
        );
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}
