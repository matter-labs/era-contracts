// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {CodeOracleCallFailed, ReturnedBytecodeDoesNotMatchExpectedHash, SecondCallShouldHaveCostLessGas, ThirdCallShouldHaveSameGasCostAsSecondCall} from "contracts/SystemContractErrors.sol";

address constant REAL_CODE_ORACLE_ADDR = 0x0000000000000000000000000000000000008011;

contract CodeOracleTest {
    function callCodeOracle(
        bytes32 _versionedHash,
        bytes32 _expectedBytecodeHash
    ) external view returns (uint256 gasCost) {
        uint256 gasBefore = gasleft();

        // Call the code oracle
        (bool success, bytes memory returnedBytecode) = REAL_CODE_ORACLE_ADDR.staticcall(
            abi.encodePacked(_versionedHash)
        );

        gasCost = gasBefore - gasleft();

        // Check the result
        if (!success) {
            revert CodeOracleCallFailed();
        }

        // Check the returned bytecode
        if (keccak256(returnedBytecode) != _expectedBytecodeHash) {
            revert ReturnedBytecodeDoesNotMatchExpectedHash(keccak256(returnedBytecode), _expectedBytecodeHash);
        }
    }

    function codeOracleTest(bytes32 _versionedHash, bytes32 _expectedBytecodeHash) external view {
        // Here we call code oracle twice in order to ensure that the memory page is preserved and the gas cost is lower the second time.
        // Note, that we use external calls in order to remove any possibility of inlining by the compiler.
        uint256 firstCallCost = this.callCodeOracle(_versionedHash, _expectedBytecodeHash);
        uint256 secondCallCost = this.callCodeOracle(_versionedHash, _expectedBytecodeHash);
        uint256 thirdCallCost = this.callCodeOracle(_versionedHash, _expectedBytecodeHash);

        if (secondCallCost >= firstCallCost) {
            revert SecondCallShouldHaveCostLessGas(secondCallCost, firstCallCost);
        }
        if (thirdCallCost != secondCallCost) {
            revert ThirdCallShouldHaveSameGasCostAsSecondCall(thirdCallCost, secondCallCost);
        }
    }
}
