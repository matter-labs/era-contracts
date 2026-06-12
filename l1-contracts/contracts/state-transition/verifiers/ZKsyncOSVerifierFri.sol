// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {
    EmptyProofLength,
    EmptyPublicInputsLength,
    InvalidProof,
    InvalidProofFormat
} from "../../common/L1ContractErrors.sol";
import {
    PUBLIC_INPUT_SHIFT,
    ZKSYNC_OS_FRI_PRECOMPILE_ADDR,
    ZKSYNC_OS_FRI_STATEMENT_HASH_VERSION
} from "../../common/Config.sol";

/// @title ZKsync OS FRI verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Verifier adapter for Gateway-mode ZKsync OS FRI proofs.
/// @dev The actual FRI proof bytes are carried by `FriProofTx` sidecar data and
/// verified by ZKsync OS. This contract binds the state-transition public inputs
/// to the public input hash returned by the proven ZKsync OS program, combines
/// it with the stored chain-recursion verification key hash, derives the
/// `statement_versioned_hash`, and asks the Gateway FRI precompile whether that
/// statement was verified in the current transaction.
contract ZKsyncOSVerifierFri is IVerifier {
    /// @dev Chain-recursion hash returned in FRI verifier output words 8..15.
    bytes32 public immutable CHAIN_RECURSION_HASH;

    constructor(bytes32 _chainRecursionHash) {
        CHAIN_RECURSION_HASH = _chainRecursionHash;
    }

    /// @inheritdoc IVerifier
    /// @dev `_proof[0]` is the full 32-byte ZKsync OS public input hash
    /// returned in Airbender output registers `x10..x17`. The recursion-chain
    /// hash is stored on this verifier as `CHAIN_RECURSION_HASH`.
    ///
    /// The L1 state-transition public-input convention stores only the top
    /// 224 bits, so this function checks `_proof[0] >> 32` against the hash
    /// derived from `_publicInputs`. The current ZKsync OS FRI path produces
    /// one public input hash per verifier run, so multi-input aggregation is
    /// rejected until the prover-side chaining convention is fixture-tested.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external view returns (bool) {
        if (_publicInputs.length == 0) {
            revert EmptyPublicInputsLength();
        }
        if (_publicInputs.length != 1) {
            revert InvalidProofFormat();
        }
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }
        if (_proof.length != 1) {
            revert InvalidProofFormat();
        }

        bytes32 publicInputHash = bytes32(_proof[0]);
        if ((_proof[0] >> PUBLIC_INPUT_SHIFT) != computeZKsyncOSHash(0, _publicInputs)) {
            revert InvalidProof();
        }

        bytes32 statementVersionedHash = computeStatementVersionedHash(publicInputHash);

        // The ZKsync OS FRI precompile expects raw 32-byte calldata (just the
        // statement hash, no function selector), so a typed interface call is
        // not possible here and a raw `staticcall` is used instead.
        (bool success, bytes memory returnData) = ZKSYNC_OS_FRI_PRECOMPILE_ADDR.staticcall(
            abi.encodePacked(statementVersionedHash)
        );
        if (!success || returnData.length != 32) {
            revert InvalidProof();
        }

        // The precompile only ever returns ABI-encoded 0 or 1; treat anything
        // else as malformed output rather than relying on `abi.decode(..., bool)`.
        uint256 decoded = abi.decode(returnData, (uint256));
        if (decoded > 1) {
            revert InvalidProof();
        }
        return decoded == 1;
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view returns (bytes32) {
        return CHAIN_RECURSION_HASH;
    }

    /// @notice Computes the FRI statement hash consumed by the Gateway FRI precompile.
    /// @param _publicInputHash The full 32-byte ZKsync OS public input hash.
    function computeStatementVersionedHash(bytes32 _publicInputHash) public view returns (bytes32 result) {
        result = keccak256(abi.encodePacked(_publicInputHash, CHAIN_RECURSION_HASH));
        result = bytes32((uint256(result) & ((1 << 248) - 1)) | (uint256(ZKSYNC_OS_FRI_STATEMENT_HASH_VERSION) << 248));
    }

    /// @notice Computes the public-input hash used by ZKsync OS recursive verification.
    function computeZKsyncOSHash(
        uint256 initialHash,
        uint256[] calldata _publicInputs
    ) public pure returns (uint256 result) {
        uint256 publicInputsLength = _publicInputs.length;
        result = initialHash;

        if (publicInputsLength == 0) {
            if (result == 0) {
                revert EmptyPublicInputsLength();
            }
            return result;
        }

        uint256 i = 0;

        if (result == 0) {
            result = _publicInputs[0];
            i = 1;
        }

        for (; i < publicInputsLength; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _publicInputs[i]))) >> PUBLIC_INPUT_SHIFT;
        }
    }
}
