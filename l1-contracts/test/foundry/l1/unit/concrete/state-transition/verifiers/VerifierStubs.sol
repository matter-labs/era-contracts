// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {AIRBENDER_PROOF_SYSTEM_MASK, BOOJUM_PROOF_SYSTEM_MASK, DisabledProofSystems} from "contracts/common/Config.sol";

/// @notice Returns a fixed verdict and key.
contract StubVerifier is IVerifier, IVerifierV2 {
    bool internal immutable RESULT;
    bytes32 internal immutable KEY;

    constructor(bool _result, bytes32 _key) {
        RESULT = _result;
        KEY = _key;
    }

    function verify(
        uint256[] calldata,
        uint256[] calldata
    ) external view override(IVerifier, IVerifierV2) returns (bool) {
        return RESULT;
    }

    function verificationKeyHash() external view override(IVerifier, IVerifierV2) returns (bytes32) {
        return KEY;
    }
}

/// @notice Accepts only the public input it was constructed with.
contract ExpectingVerifier is IVerifier {
    uint256 internal immutable EXPECTED;

    constructor(uint256 _expected) {
        EXPECTED = _expected;
    }

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external view returns (bool) {
        return _publicInputs.length == 1 && _publicInputs[0] == EXPECTED;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Reveals what it was called with by reverting (`verify` is view).
contract RevealingVerifier is IVerifier {
    error Revealed(uint256 firstPublicInput, uint256 publicInputCount, uint256 firstProofWord, uint256 proofLength);

    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external pure returns (bool) {
        revert Revealed(
            _publicInputs.length == 0 ? 0 : _publicInputs[0],
            _publicInputs.length,
            _proof.length == 0 ? type(uint256).max : _proof[0],
            _proof.length
        );
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Reveals how many public inputs it was called with by reverting.
contract CountingVerifier is IVerifier {
    error Count(uint256 publicInputCount);

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external pure returns (bool) {
        revert Count(_publicInputs.length);
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Stands in for the chain diamond the verifier reads `disabledProofSystems` from.
contract ChainStub {
    uint8 internal mask;

    function setDisabledProofSystems(uint8 _mask) external {
        mask = _mask;
    }

    function disabledProofSystems() external view returns (DisabledProofSystems memory) {
        return
            DisabledProofSystems({
                boojum: mask & BOOJUM_PROOF_SYSTEM_MASK != 0,
                airbender: mask & AIRBENDER_PROOF_SYSTEM_MASK != 0
            });
    }

    function callVerify(
        IVerifier _verifier,
        uint256[] calldata _pi,
        uint256[] calldata _proof
    ) external view returns (bool) {
        return _verifier.verify(_pi, _proof);
    }
}
