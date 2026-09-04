// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

contract L2ContractHelperTest is Test {
    function test_hashFactoryDeps_emptyArray() public pure {
        uint256[] memory hashedFactoryDeps = L2ContractHelper.hashFactoryDeps(new bytes[](0));

        assertEq(hashedFactoryDeps.length, 0);
    }

    function test_hashFactoryDeps_acceptsArbitraryEvmBytecodeLengths() public pure {
        bytes[] memory factoryDeps = new bytes[](4);
        factoryDeps[0] = hex"";
        factoryDeps[1] = hex"00";
        factoryDeps[2] = hex"6001600055";
        factoryDeps[3] = new bytes(33);

        uint256[] memory hashedFactoryDeps = L2ContractHelper.hashFactoryDeps(factoryDeps);

        assertEq(hashedFactoryDeps.length, factoryDeps.length);
        for (uint256 i = 0; i < factoryDeps.length; ++i) {
            assertEq(
                hashedFactoryDeps[i],
                uint256(ZKSyncOSBytecodeInfo.hashEVMBytecode(factoryDeps[i])),
                "wrong observable bytecode hash"
            );
        }
    }

    function test_hashFactoryDeps_preservesOrder() public pure {
        bytes[] memory factoryDeps = new bytes[](2);
        factoryDeps[0] = hex"6001600055";
        factoryDeps[1] = hex"6002600055";

        uint256[] memory hashedFactoryDeps = L2ContractHelper.hashFactoryDeps(factoryDeps);

        assertEq(hashedFactoryDeps[0], uint256(keccak256(factoryDeps[0])));
        assertEq(hashedFactoryDeps[1], uint256(keccak256(factoryDeps[1])));
        assertNotEq(hashedFactoryDeps[0], hashedFactoryDeps[1]);
    }

    function testFuzz_hashFactoryDeps_usesObservableBytecodeHash(bytes memory _bytecode) public pure {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = _bytecode;

        uint256[] memory hashedFactoryDeps = L2ContractHelper.hashFactoryDeps(factoryDeps);

        assertEq(hashedFactoryDeps.length, 1);
        assertEq(hashedFactoryDeps[0], uint256(keccak256(_bytecode)));
    }
}
