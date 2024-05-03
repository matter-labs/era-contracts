// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Auxiliary{
    function bytecodeHash(address _addr) public view returns (bytes32 hash) {
        bytes32 codeHash;    
        assembly { codeHash := extcodehash(_addr) }
        return codeHash;
    }
}