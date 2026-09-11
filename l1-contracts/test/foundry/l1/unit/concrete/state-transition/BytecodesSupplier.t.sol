// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "contracts/upgrades/BytecodesSupplier.sol";
import "contracts/common/l2-helpers/L2ContractHelper.sol";
import "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import "contracts/common/L1ContractErrors.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract BytecodesSupplierTest is Test {
    BytecodesSupplier bytecodesSupplier;
    bytes internal bytecode1 = hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal bytecode2 = hex"1111111111111111111111111111111111111111111111111111111111111111";
    // EVM bytecodes can be arbitrary bytes (no specific format requirements)
    bytes internal evmBytecode1 = hex"6080604052";
    bytes internal evmBytecode2 = hex"6080604052348015600f57600080fd5b50";

    // Declare the events to use with vm.expectEmit
    event EVMBytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);

    function setUp() public {
        // Deploy with transparent upgradeable proxy
        // Use a separate admin address to avoid "admin cannot fallback to proxy target" error
        address proxyAdmin = makeAddr("proxyAdmin");
        BytecodesSupplier implementation = new BytecodesSupplier();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            abi.encodeCall(BytecodesSupplier.initialize, ())
        );
        bytecodesSupplier = BytecodesSupplier(address(proxy));
    }

    function testPublishNewEVMBytecode() public {
        bytes memory bytecode = evmBytecode1;

        // Calculate the bytecode hash using ZKSyncOSBytecodeInfo.hashEVMBytecode
        bytes32 bytecodeHash = ZKSyncOSBytecodeInfo.hashEVMBytecode(bytecode);

        // Expect the event to be emitted
        vm.expectEmit(true, false, false, true);
        emit EVMBytecodePublished(bytecodeHash, bytecode);

        // Publish the bytecode
        bytecodesSupplier.publishEVMBytecode(bytecode);

        // Check that the evmPublishingBlock mapping is updated
        uint256 publishedBlock = bytecodesSupplier.evmPublishingBlock(bytecodeHash);
        assertEq(publishedBlock, block.number);
    }

    function testPublishEVMBytecodeAlreadyPublished() public {
        bytes memory bytecode = evmBytecode1;

        // Calculate the bytecode hash
        bytes32 bytecodeHash = ZKSyncOSBytecodeInfo.hashEVMBytecode(bytecode);

        // Publish the bytecode
        bytecodesSupplier.publishEVMBytecode(bytecode);

        // Try to publish the same bytecode again, expect revert
        vm.expectRevert(abi.encodeWithSelector(EVMBytecodeAlreadyPublished.selector, bytecodeHash));
        bytecodesSupplier.publishEVMBytecode(bytecode);
    }

    function testPublishMultipleEVMBytecodes() public {
        bytes[] memory bytecodes = new bytes[](2);
        bytecodes[0] = evmBytecode1;
        bytecodes[1] = evmBytecode2;

        // Expect events for each bytecode published
        for (uint256 i = 0; i < bytecodes.length; ++i) {
            bytes32 bytecodeHash = ZKSyncOSBytecodeInfo.hashEVMBytecode(bytecodes[i]);
            vm.expectEmit(true, false, false, true);
            emit EVMBytecodePublished(bytecodeHash, bytecodes[i]);
        }

        // Publish multiple bytecodes
        bytecodesSupplier.publishEVMBytecodes(bytecodes);

        // Check that both bytecodes are published
        for (uint256 i = 0; i < bytecodes.length; ++i) {
            bytes32 bytecodeHash = ZKSyncOSBytecodeInfo.hashEVMBytecode(bytecodes[i]);
            uint256 publishedBlock = bytecodesSupplier.evmPublishingBlock(bytecodeHash);
            assertEq(publishedBlock, block.number);
        }
    }

    function testPublishMultipleEVMBytecodesWithDuplicate() public {
        bytes[] memory bytecodes = new bytes[](2);
        bytecodes[0] = evmBytecode1;
        bytecodes[1] = evmBytecode2;

        // Publish the first bytecode
        bytecodesSupplier.publishEVMBytecode(bytecodes[0]);

        // Calculate the bytecode hash of the first bytecode
        bytes32 bytecodeHash = ZKSyncOSBytecodeInfo.hashEVMBytecode(bytecodes[0]);

        // Now try to publish both bytecodes, one of which is already published
        vm.expectRevert(abi.encodeWithSelector(EVMBytecodeAlreadyPublished.selector, bytecodeHash));
        bytecodesSupplier.publishEVMBytecodes(bytecodes);
    }

    // ============ Cross-type Tests ============
}
