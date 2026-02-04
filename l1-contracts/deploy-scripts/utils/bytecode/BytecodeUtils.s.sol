// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

library BytecodeUtils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /**
     * @dev Returns the bytecode of a given system contract.
     */
    function readSystemContractsBytecode(string memory filename) internal view returns (bytes memory) {
        return readZKFoundryBytecodeSystemContracts(string.concat(filename, ".sol"), filename);
    }

    /**
     * @dev Returns the bytecode of a given system contract in yul.
     */
    function readSystemContractsYulBytecode(string memory filename) internal view returns (bytes memory) {
        string memory path = string.concat("/../system-contracts/zkout/", filename, ".yul/", filename, ".json");

        return readFoundryBytecode(path);
    }

    /**
     * @dev Returns the bytecode of a given precompile system contract.
     */
    function readPrecompileBytecode(string memory filename) internal view returns (bytes memory) {
        string memory path = string.concat("/../system-contracts/zkout/", filename, ".yul/", filename, ".json");

        return readFoundryBytecode(path);
    }
    /**
     * @dev Returns the bytecode of a given DA contract.
     */
    function readDAContractBytecode(string memory contractIdentifier) internal view returns (bytes memory) {
        return
            readFoundryBytecode(
                string.concat("/../da-contracts/out/", contractIdentifier, ".sol/", contractIdentifier, ".json")
            );
    }

    /**
     * @dev Read foundry bytecodes
     */
    function readFoundryBytecode(string memory artifactPath) internal view returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, artifactPath);
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode.object");
        return bytecode;
    }

    function readFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/out/", fileName, "/", contractName, ".json");
        return readFoundryBytecode(path);
    }

    function readZKFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    function readZKFoundryBytecodeL2(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l2-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    function readZKFoundryBytecodeSystemContracts(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../system-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
