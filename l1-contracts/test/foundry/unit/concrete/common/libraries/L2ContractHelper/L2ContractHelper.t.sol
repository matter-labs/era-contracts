// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {MalformedBytecode, BytecodeError, LengthIsNotDivisibleBy32} from "contracts/common/L1ContractErrors.sol";

contract L2ContractHelperTest is Test {
    address daiOnEthereum = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address daiOnEra = 0x4B9eb6c0b6ea15176BBF62841C6B2A8a398cb656;

    address l2Bridge = 0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102;
    address l2TokenBeacon = 0x1Eb710030273e529A6aD7E1e14D4e601765Ba3c6;
    bytes32 l2TokenProxyBytecodeHash = 0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019;

    // Bytecode must be provided in 32-byte words
    function test_RevertWhen_BytecodeLengthIsNotMultipleOf32() public {
        bytes memory bytecode = new bytes(63);

        vm.expectRevert(abi.encodeWithSelector(LengthIsNotDivisibleBy32.selector, 63));
        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);
    }

    // Bytecode length must be less than 2^16 words
    function test_RevertWhen_BytecodeLengthIsTooLarge() public {
        bytes memory bytecode = new bytes(2 ** 16 * 32);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.NumberOfWords));
        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);
    }

    // Bytecode length in words must be odd
    function test_RevertWhen_BytecodeLengthIsNotOdd() public {
        bytes memory bytecode = new bytes(64);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.WordsMustBeOdd));
        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);
    }

    function test_SuccessfulHashing() public {
        bytes memory bytecode = new bytes(32);
        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);

        assertEq(hash, bytes32(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925));
    }

    // Incorrectly formatted bytecodeHash
    function test_RevertWhen_BytecodeHashVersionIsNotOne() public {
        bytes32 bytecodeHash = bytes32(0x02000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.Version));
        L2ContractHelper.validateBytecodeHash(bytecodeHash);
    }

    // Code length in words must be odd
    function test_RevertWhen_CodeLengthInWordsIsNotOdd() public {
        bytes32 bytecodeHash = bytes32(0x01000002f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.WordsMustBeOdd));
        L2ContractHelper.validateBytecodeHash(bytecodeHash);
    }

    function test_SuccessfulValidation() public {
        bytes32 bytecodeHash = bytes32(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        L2ContractHelper.validateBytecodeHash(bytecodeHash);
    }

    // computeCreate2Address
    function test_ComputeCreate2Address() public {
        bytes32 constructorInputHash = keccak256(abi.encode(l2TokenBeacon, ""));
        bytes32 salt = bytes32(uint256(uint160(daiOnEthereum)));

        address computedAddress = L2ContractHelper.computeCreate2Address(
            l2Bridge,
            salt,
            l2TokenProxyBytecodeHash,
            constructorInputHash
        );

        assertEq(computedAddress, daiOnEra);
    }
}
