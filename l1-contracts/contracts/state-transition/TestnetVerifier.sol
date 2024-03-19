// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IVerifier} from "./chain-interfaces/IVerifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to skip the zkp verification for the testnet environment.
/// If the proof is not empty, it will verify it using the main verifier contract,
/// otherwise, it will skip the verification.
contract TestnetVerifier is IVerifier {
    IVerifier immutable mainVerifier;

    constructor(address _mainVerifier) {
        assert(block.chainid != 1);
        mainVerifier = IVerifier(_mainVerifier);
    }

    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof,
        uint256[] calldata _recursiveAggregationInput
    ) external view returns (bool) {
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.length == 0) {
            return true;
        }

        return mainVerifier.verify(_publicInputs, _proof, _recursiveAggregationInput);
    }

    function verificationKeyHash() external view returns (bytes32) {
        return mainVerifier.verificationKeyHash();
    }
}
