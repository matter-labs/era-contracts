// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";

/// @title Generic Testnet Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Wraps any IVerifier and adds mock proof support for testnet environments.
///         - Empty proofs: accepted unconditionally (skip verification).
///         - Mock proofs (type 3): validated for public input consistency, no cryptographic check.
///         - All other proofs: delegated to the inner verifier.
/// @dev Can wrap DualVerifier, MultiProofVerifier, or any other IVerifier implementation.
contract TestnetVerifier is IVerifier {
    uint256 internal constant MOCK_PROOF_TYPE = 3;

    IVerifier public immutable innerVerifier;

    error InvalidMockProof();

    constructor(IVerifier _innerVerifier) {
        assert(block.chainid != 1);
        innerVerifier = _innerVerifier;
    }

    /// @inheritdoc IVerifier
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view override returns (bool) {
        // Empty proof: skip verification entirely (testnet convenience).
        if (_proof.length == 0) {
            return true;
        }

        // Mock proof (type 3): validate public input consistency without cryptographic check.
        if ((_proof[0] & 255) == MOCK_PROOF_TYPE) {
            return _mockVerify(_publicInputs, _proof);
        }

        // Everything else: delegate to the real verifier.
        return innerVerifier.verify(_publicInputs, _proof);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return innerVerifier.verificationKeyHash();
    }

    /// @dev Mock verification: proof = [type=3, prevHash, magic(13), publicInput].
    function _mockVerify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) internal pure returns (bool) {
        require(_proof.length >= 4, "mock proof too short");

        // Compute hash the same way as production verifiers.
        uint256 result = _proof[1]; // previous hash
        uint256 i = 0;
        if (result == 0) {
            result = _publicInputs[0];
            i = 1;
        }
        for (; i < _publicInputs.length; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _publicInputs[i]))) >> 32;
        }

        if (_proof[2] != 13 || _proof[3] != result) {
            revert InvalidMockProof();
        }
        return true;
    }
}
