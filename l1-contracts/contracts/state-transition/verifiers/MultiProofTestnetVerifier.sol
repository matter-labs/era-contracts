// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";
import {NonZeroCarriedHash} from "../../common/L1ContractErrors.sol";
import {PUBLIC_INPUT_SHIFT} from "../../common/Config.sol";

/// @title Generic Testnet Verifier (multi-proof lane)
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Wraps any IVerifier and adds mock proof support for testnet environments.
///         - Empty proofs: accepted unconditionally (skip verification).
///         - Mock proofs (type 3): validated for public input consistency, no cryptographic check.
///         - All other proofs: delegated to the inner verifier.
/// @dev Can wrap DualVerifier, MultiProofVerifier, or any other IVerifier implementation.
///      Named distinctly from the DualVerifier-based `TestnetVerifier` upstream ships.
contract MultiProofTestnetVerifier is IVerifier, IZKsyncOSVerifier {
    uint256 internal constant MOCK_PROOF_TYPE = 3;

    IVerifier public immutable INNER_VERIFIER;

    error InvalidMockProof();
    error MockProofTooShort();

    constructor(IVerifier _innerVerifier) {
        assert(block.chainid != 1);
        INNER_VERIFIER = _innerVerifier;
    }

    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view override returns (bool) {
        // Empty proof: skip verification entirely (testnet convenience).
        if (_proof.length == 0) {
            return true;
        }

        // Mock proof (type 3): validate public input consistency without cryptographic check.
        if ((_proof[0] & 255) == MOCK_PROOF_TYPE) {
            return _mockVerify(_publicInputs, _proof);
        }

        // Everything else: delegate to the real verifier.
        return INNER_VERIFIER.verify(_publicInputs, _proof);
    }

    /// @notice The proof systems a chain behind this wrapper does not require.
    /// @dev The wrapper stands between the chain and the inner verifier, so the inner verifier reads
    ///      this contract rather than the chain. It answers `0`, requiring every proof system: the mock
    ///      proof route is the bypass this wrapper provides, and it is the one a test chain uses. The
    ///      switch that trades a proof system for liveness belongs to production chains, which reach the
    ///      inner verifier directly.
    function disabledProofSystems() external pure returns (uint8) {
        return 0;
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return INNER_VERIFIER.verificationKeyHash();
    }

    /// @notice The PLONK sub-verifier of the wrapped ZKsync OS verifier.
    /// @dev The chain's verifier is this wrapper, and deployment and upgrade
    ///      tooling introspects the sub-verifier through it. The sub-verifier
    ///      itself stays in the one ZKsync OS verifier at the end of the
    ///      wrapping chain.
    // solhint-disable-next-line func-name-mixedcase
    function PLONK_VERIFIER() external view returns (IVerifier) {
        return IZKsyncOSVerifier(address(INNER_VERIFIER)).PLONK_VERIFIER();
    }

    /// @dev Mock verification: proof = [type=3, carried hash, magic(13), publicInput].
    ///      The expected public input is the value the settlement layer defines,
    ///      so a mock settle and a real settle agree on what a batch range
    ///      carries. A mock proof that had to be built against a second rule
    ///      would test the rule rather than the chain.
    function _mockVerify(uint256[] calldata _publicInputs, uint256[] calldata _proof) internal pure returns (bool) {
        if (_proof.length < 4) revert MockProofTooShort();

        // The carried-hash slot holds a continuation input that the settlement
        // layer does not accept, so it stays reserved and must be zero.
        if (_proof[1] != 0) {
            revert NonZeroCarriedHash();
        }

        // Mirrors `ZKsyncOSVerifier.computeZKsyncOSHash` from seed 0: one
        // keccak256 over the concatenated untruncated inputs, shifted once. A
        // single batch carries its own public input, and the shift applies to
        // it as well.
        uint256 result = _publicInputs.length == 1
            ? _publicInputs[0]
            : uint256(keccak256(abi.encodePacked(_publicInputs)));
        result = result >> PUBLIC_INPUT_SHIFT;

        if (_proof[2] != 13 || _proof[3] != result) {
            revert InvalidMockProof();
        }
        return true;
    }
}
