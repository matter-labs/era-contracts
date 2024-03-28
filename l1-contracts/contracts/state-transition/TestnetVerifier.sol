// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Verifier} from "./Verifier.sol";
import {IVerifier} from "./chain-interfaces/IVerifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to skip the zkp verification for the testnet environment.
/// If the proof is not empty, it will verify it using the main verifier contract,
/// otherwise, it will skip the verification.
contract TestnetVerifier is Verifier {
    constructor() {
        assert(block.chainid != 1);
    }

    /// @dev Verifies a zk-SNARK proof, skipping the verification if the proof is empty.
    /// @inheritdoc IVerifier
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof,
        uint256[] calldata _recursiveAggregationInput
    ) public view override returns (bool) {
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.length == 0) {
            return true;
        }

        return super.verify(_publicInputs, _proof, _recursiveAggregationInput);
    }
}
