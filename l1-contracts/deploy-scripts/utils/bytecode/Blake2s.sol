// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice blake2s-256 hashes of bytecodes, computed by `scripts/blake2s256.js` over FFI.
library Blake2s {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // solhint-disable-next-line const-name-snakecase
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice The blake2s-256 hash of `_bytecode`.
    /// @param _bytecode The bytes to hash.
    function hash(bytes memory _bytecode) internal returns (bytes32) {
        string[] memory input = new string[](3);
        input[0] = "node";
        input[1] = "./scripts/blake2s256.js";
        input[2] = vm.toString(_bytecode);
        return bytes32(vm.ffi(input));
    }

    /// @notice The blake2s-256 hashes of `_bytecodes`, index-aligned, computed in one FFI process.
    /// @dev Prefer it to repeated {hash} calls when hashing many bytecodes: each FFI process costs
    ///      Forge script memory, and a large inventory hashed one by one exceeds its cap.
    /// @param _bytecodes The bytes to hash.
    /// @param _scratchFile The file the batch reaches the FFI process through. It is overwritten,
    ///        then removed, so concurrent runs need distinct paths.
    /// @return hashes The hash of each element of `_bytecodes`.
    function hashBatch(
        bytes[] memory _bytecodes,
        string memory _scratchFile
    ) internal returns (bytes32[] memory hashes) {
        vm.writeFile(_scratchFile, "");
        for (uint256 i = 0; i < _bytecodes.length; i++) {
            vm.writeLine(_scratchFile, vm.toString(_bytecodes[i]));
        }

        string[] memory input = new string[](4);
        input[0] = "node";
        input[1] = "./scripts/blake2s256.js";
        input[2] = "--batch";
        input[3] = _scratchFile;
        bytes memory result = vm.ffi(input);

        require(result.length == _bytecodes.length * 32, "Unexpected batch blake2s result length");
        hashes = new bytes32[](_bytecodes.length);
        for (uint256 i = 0; i < _bytecodes.length; i++) {
            bytes32 bytecodeHash;
            assembly {
                bytecodeHash := mload(add(result, add(32, mul(i, 32))))
            }
            hashes[i] = bytecodeHash;
        }
        vm.removeFile(_scratchFile);
    }
}
