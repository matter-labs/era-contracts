// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "contracts/upgrades/BytecodesSupplier.sol";
import "contracts/common/libraries/L2ContractHelper.sol";
import "contracts/common/L1ContractErrors.sol";

contract BytecodesSupplierTest is Test {
    BytecodesSupplier bytecodesSupplier;
    bytes internal bytecode1 = hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal bytecode2 = hex"1111111111111111111111111111111111111111111111111111111111111111";

    // Declare the event to use with vm.expectEmit
    event BytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);

    function setUp() public {
        bytecodesSupplier = new BytecodesSupplier();
    }

    function testPublishNewBytecode() public {
        bytes memory bytecode = bytecode1;

        // Calculate the bytecode hash using the same function as the contract
        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        // Expect the event to be emitted
        vm.expectEmit(true, false, false, true);
        emit BytecodePublished(bytecodeHash, bytecode);

        // Publish the bytecode
        bytecodesSupplier.publishBytecode(bytecode);

        // Check that the publishingBlock mapping is updated
        uint256 publishedBlock = bytecodesSupplier.publishingBlock(bytecodeHash);
        assertEq(publishedBlock, block.number);
    }

    function testPublishBytecodeAlreadyPublished() public {
        bytes memory bytecode = bytecode1;

        // Calculate the bytecode hash
        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        // Publish the bytecode
        bytecodesSupplier.publishBytecode(bytecode);

        // Try to publish the same bytecode again, expect revert
        vm.expectRevert(abi.encodeWithSelector(BytecodeAlreadyPublished.selector, bytecodeHash));
        bytecodesSupplier.publishBytecode(bytecode);
    }

    function testPublishMultipleBytecodes() public {
        bytes[] memory bytecodes = new bytes[](2);
        bytecodes[0] = bytecode1;
        bytecodes[1] = bytecode2;

        // Expect events for each bytecode published
        for (uint256 i = 0; i < bytecodes.length; ++i) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecodes[i]);
            vm.expectEmit(true, false, false, true);
            emit BytecodePublished(bytecodeHash, bytecodes[i]);
        }

        // Publish multiple bytecodes
        bytecodesSupplier.publishBytecodes(bytecodes);

        // Check that both bytecodes are published
        for (uint256 i = 0; i < bytecodes.length; ++i) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecodes[i]);
            uint256 publishedBlock = bytecodesSupplier.publishingBlock(bytecodeHash);
            assertEq(publishedBlock, block.number);
        }
    }

    function testPublishMultipleBytecodesWithDuplicate() public {
        bytes[] memory bytecodes = new bytes[](2);
        bytecodes[0] = bytecode1;
        bytecodes[1] = bytecode2;

        // Publish the first bytecode
        bytecodesSupplier.publishBytecode(bytecodes[0]);

        // Calculate the bytecode hash of the first bytecode
        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecodes[0]);

        // Now try to publish both bytecodes, one of which is already published
        vm.expectRevert(abi.encodeWithSelector(BytecodeAlreadyPublished.selector, bytecodeHash));
        bytecodesSupplier.publishBytecodes(bytecodes);
    }
}
