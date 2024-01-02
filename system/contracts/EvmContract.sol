// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Constants.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";

contract EvmContract {
    fallback() external payable {
        bytes memory data = new bytes(msg.data.length + 0x20);
        address addr = SystemContractHelper.getCodeAddress();
        assembly {
            mstore(add(data, 0x20), addr)
            calldatacopy(add(data, 0x40), 0, calldatasize())
        }

        (bool success, bytes memory res) = address(EVM_INTERPRETER).delegatecall(data);

        assembly {
            if iszero(success) {
                revert(add(res, 0x20), mload(res))
            }

            return(add(res, 0x20), mload(res))
        }
    }
}
