// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

library BytecodeUtils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

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

    /// @notice Read L1 creation bytecode from the correct artifact directory.
    ///         EVM bytecodes → out/, ZK bytecodes → zkout/.
    /// @dev TODO(gateway-os): the ZK (zkout) arm is only reachable from retained legacy-Gateway upgrade
    /// scripts; the EraVM artifacts it reads are no longer built.
    function readBytecodeL1(
        bool _isEVMBytecode,
        string memory _fileName,
        string memory _contractName
    ) internal view returns (bytes memory) {
        return
            _isEVMBytecode
                ? readFoundryBytecodeL1(_fileName, _contractName)
                : readZKFoundryBytecodeL1(_fileName, _contractName);
    }

    function readFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) private view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/out/", fileName, "/", contractName, ".json");
        return readFoundryBytecode(path);
    }

    function readZKFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) private view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    // ======================== Deployed bytecode reading ========================

    function readFoundryDeployedBytecode(string memory _artifactPath) internal view returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, _artifactPath);
        string memory json = vm.readFile(path);
        return vm.parseJsonBytes(json, ".deployedBytecode.object");
    }

    /// @notice Read L1 deployed bytecode from the correct artifact directory.
    ///         EVM bytecodes → out/ (EVM deployed bytecode), ZK bytecodes → zkout/ (ZK creation bytecode).
    function readDeployedBytecodeL1(
        bool _isEVMBytecode,
        string memory _fileName,
        string memory _contractName
    ) internal view returns (bytes memory) {
        if (_isEVMBytecode) {
            string memory path = string.concat("/../l1-contracts/out/", _fileName, "/", _contractName, ".json");
            return readFoundryDeployedBytecode(path);
        }
        return readZKFoundryBytecodeL1(_fileName, _contractName);
    }

    // ======================== Bytecode hashing ========================

    /// @notice Hash EVM bytecode (keccak256).
    function hashBytecode(bool _isEVMBytecode, bytes memory _bytecode) internal pure returns (bytes32) {
        require(_isEVMBytecode, "EraVM (ZK) bytecode hashing is not supported");
        return keccak256(_bytecode);
    }

    /// @notice Read and hash deployed EVM bytecode (keccak256) in one call.
    function getDeployedBytecodeHash(
        bool _isEVMBytecode,
        string memory _fileName,
        string memory _contractName
    ) internal view returns (bytes32) {
        return hashBytecode(_isEVMBytecode, readDeployedBytecodeL1(_isEVMBytecode, _fileName, _contractName));
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
