// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

library Utils {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    Vm internal constant vm = Vm(VM_ADDRESS);

    function getAllSelectors(bytes memory bytecode) internal returns (bytes4[] memory) {
        string[] memory input = new string[](3);
        input[0] = "cast";
        input[1] = "selectors";
        input[2] = vm.toString(bytecode);
        bytes memory result = vm.ffi(input);
        string memory stringResult = string(abi.encodePacked(result));

        // Extract selectors from the result
        string[] memory parts = vm.split(stringResult, "\n");
        bytes4[] memory selectors = new bytes4[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            bytes memory part = bytes(parts[i]);
            bytes memory extractedSelector = new bytes(10);
            // Selector length 10 is 0x + 4 bytes
            for (uint256 j = 0; j < 10; j++) {
                extractedSelector[j] = part[j];
            }
            bytes4 selector = bytes4(vm.parseBytes(string(extractedSelector)));
            selectors[i] = selector;
        }

        return selectors;
    }

    function bytesToAddress(bytes memory bys) internal pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 20))
        }
    }
}
