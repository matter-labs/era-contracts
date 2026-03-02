// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ContractsBytecodesLib} from "deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";

library Utils {
    function deployEIP7702Checker() internal returns (address) {
        bytes memory bytecode = ContractsBytecodesLib.getCreationCodeEVM("EIP7702Checker");

        return deployViaCreate(bytecode);
    }

    /**
     * @dev Deploys contract using CREATE.
     */
    function deployViaCreate(bytes memory _bytecode) internal returns (address addr) {
        if (_bytecode.length == 0) {
            revert("Bytecode is not set");
        }

        assembly {
            // Allocate memory for the bytecode
            let size := mload(_bytecode) // Load the size of the bytecode
            let ptr := add(_bytecode, 0x20) // Skip the length prefix (32 bytes)

            // Create the contract
            addr := create(0, ptr, size)
        }

        require(addr != address(0), "Deployment failed");
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
