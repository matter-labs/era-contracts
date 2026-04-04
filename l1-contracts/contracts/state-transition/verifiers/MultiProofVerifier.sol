// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

/// @title Multi-Proof Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Requires BOTH an Airbender proof and a ZiSK proof for each state transition.
///         Only accepts the combined proof type (MULTI_PROOF_TYPE = 5) or mock proofs (type 3).
///         Single-system proofs (type 2) are rejected — both proof systems must agree.
///
/// @dev Proof encoding received from the Executor:
///      proof[0] = proof_type | (verifier_version << 8)
///      proof[1] = previous_hash (used by computeZKsyncOSHash)
///
///      For type 5 (MULTI_PROOF):
///      proof[2]           = N  (number of Airbender proof elements)
///      proof[3 .. 3+N]    = Airbender SNARK proof elements
///      proof[3+N .. 3+N+24]  = ZiSK SNARK proof (24 uint256 = 768 bytes)
///      proof[3+N+24 .. 3+N+32] = ZiSK public values (8 uint256 = 256 bytes)
///
///      The verifier strips proof[0..2] (type+version, previous_hash) and passes
///      the remaining data to each inner verifier after splitting.
contract MultiProofVerifier is Ownable2Step, IVerifier {
    uint256 internal constant MULTI_PROOF_TYPE = 5;
    uint256 internal constant MOCK_PROOF_TYPE = 3;

    /// @notice Inner verifier for Airbender proofs (implements IVerifier).
    IVerifier public airbenderVerifier;
    /// @notice Inner verifier for ZiSK proofs (implements IVerifier).
    IVerifier public ziskVerifier;

    error EmptyProof();
    error UnknownProofType(uint256 proofType);
    error ProofTooShort();
    error AirbenderVerificationFailed();
    error ZiskVerificationFailed();
    error InvalidMockProof();

    constructor(
        IVerifier _airbenderVerifier,
        IVerifier _ziskVerifier,
        address _initialOwner
    ) {
        airbenderVerifier = _airbenderVerifier;
        ziskVerifier = _ziskVerifier;
        _transferOwnership(_initialOwner);
    }

    /// @notice Update the Airbender verifier.
    function setAirbenderVerifier(IVerifier _verifier) external onlyOwner {
        airbenderVerifier = _verifier;
    }

    /// @notice Update the ZiSK verifier.
    function setZiskVerifier(IVerifier _verifier) external onlyOwner {
        ziskVerifier = _verifier;
    }

    /// @notice Verify a combined Airbender + ZiSK proof.
    /// @param _publicInputs Public inputs from the Executor (batch commitment data).
    /// @param _proof Combined proof array containing both sub-proofs.
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view virtual override returns (bool) {
        if (_proof.length == 0) revert EmptyProof();

        uint256 proofType = _proof[0] & 255;

        if (proofType == MOCK_PROOF_TYPE) {
            return _mockVerify(_publicInputs, _proof);
        }

        if (proofType == MULTI_PROOF_TYPE) {
            return _verifyMultiProof(_publicInputs, _proof);
        }

        revert UnknownProofType(proofType);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        // Return the Airbender VK hash for backward compatibility.
        return airbenderVerifier.verificationKeyHash();
    }

    /// @dev Verify a multi-proof containing both Airbender and ZiSK sub-proofs.
    function _verifyMultiProof(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) internal view returns (bool) {
        // proof[0] = type | version, proof[1] = previous_hash, proof[2] = N
        if (_proof.length < 3) revert ProofTooShort();

        uint256 airbenderLen = _proof[2];
        // Need: 3 + airbenderLen + 24 (ZiSK SNARK) + 8 (ZiSK PV) elements
        if (_proof.length < 3 + airbenderLen + 32) revert ProofTooShort();

        // Compute the public input hash the same way DualVerifier does.
        uint256[] memory args = new uint256[](1);
        args[0] = _computeZKsyncOSHash(_proof[1], _publicInputs);

        // --- Airbender verification ---
        // Extract Airbender proof elements: _proof[3 .. 3+N]
        uint256[] memory airbenderProof = new uint256[](airbenderLen);
        for (uint256 i = 0; i < airbenderLen; i++) {
            airbenderProof[i] = _proof[3 + i];
        }
        if (!airbenderVerifier.verify(args, airbenderProof)) {
            revert AirbenderVerificationFailed();
        }

        // --- ZiSK verification ---
        // Extract ZiSK data: _proof[3+N .. 3+N+32]
        // (24 SNARK elements + 8 public value elements)
        uint256 ziskStart = 3 + airbenderLen;
        uint256[] memory ziskProof = new uint256[](32);
        for (uint256 i = 0; i < 32; i++) {
            ziskProof[i] = _proof[ziskStart + i];
        }
        if (!ziskVerifier.verify(args, ziskProof)) {
            revert ZiskVerificationFailed();
        }

        return true;
    }

    /// @dev Mock verification: accepts if magic value and public input match.
    ///      Proof layout for mock: [type, prev_hash, magic(13), public_input]
    function _mockVerify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) internal pure returns (bool) {
        if (_proof.length < 4) revert ProofTooShort();
        uint256[] memory args = new uint256[](1);
        args[0] = _computeZKsyncOSHash(_proof[1], _publicInputs);

        // Standard mock check: magic value = 13, public input match.
        if (_proof[2] != 13 || _proof[3] != args[0]) {
            revert InvalidMockProof();
        }
        return true;
    }

    /// @dev Compute the ZKsync OS hash: chain public inputs with keccak256 truncated to 224 bits.
    ///      Matches DualVerifier.computeZKsyncOSHash.
    function _computeZKsyncOSHash(
        uint256 initialHash,
        uint256[] calldata _publicInputs
    ) internal pure returns (uint256 result) {
        result = initialHash;
        uint256 i = 0;
        if (result == 0) {
            result = _publicInputs[0];
            i = 1;
        }
        for (; i < _publicInputs.length; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _publicInputs[i]))) >> 32;
        }
    }
}
