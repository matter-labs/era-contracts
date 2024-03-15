// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IVerifier} from "./interfaces/IVerifier.sol";

contract TestnetVerifier is IVerifier {
    IVerifier _mainVerifier;

    constructor(address _verifier) {
        _mainVerifier = IVerifier(_verifier);
    }

    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof,
        uint256[] calldata _recursiveAggregationInput
    ) external view returns (bool) {
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        assert(block.chainid != 1);
        if (_proof.length == 0) {
            return true;
        }

        return _mainVerifier.verify(_publicInputs, _proof, _recursiveAggregationInput);
    }

    function verificationKeyHash() external view returns (bytes32) {
        return _mainVerifier.verificationKeyHash();
    }
}
