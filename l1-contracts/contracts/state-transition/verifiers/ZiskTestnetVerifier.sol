// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {
    MAINNET_CHAIN_ID,
    PUBLIC_INPUT_SHIFT,
    ZISK_SNARK_PROOF_LENGTH,
    ZKSYNC_OS_MOCK_PROOF_MAGIC,
    ZKSYNC_OS_MOCK_VERIFICATION_TYPE
} from "../../common/Config.sol";

/// @title ZiSK Testnet Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Adds canonical fake-component support to a ZiSK range verifier on testnets.
/// @dev A real ZiSK proof has no type header. The three-word mock marker therefore
///      identifies the fake path together; every other proof is delegated unchanged.
contract ZiskTestnetVerifier is IVerifier {
    IVerifier public immutable INNER_VERIFIER;

    error InvalidMockProof();

    constructor(IVerifier _innerVerifier) {
        assert(block.chainid != MAINNET_CHAIN_ID);
        INNER_VERIFIER = _innerVerifier;
    }

    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) external view override returns (bool) {
        if (_isMockProof(_proof)) {
            return _mockVerify(_publicInputs, _proof);
        }

        return INNER_VERIFIER.verify(_publicInputs, _proof);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return INNER_VERIFIER.verificationKeyHash();
    }

    function _isMockProof(uint256[] calldata _proof) private pure returns (bool) {
        return
            _proof.length == ZISK_SNARK_PROOF_LENGTH &&
            _proof[0] == ZKSYNC_OS_MOCK_VERIFICATION_TYPE &&
            _proof[1] == 0 &&
            _proof[2] == ZKSYNC_OS_MOCK_PROOF_MAGIC;
    }

    function _mockVerify(uint256[] calldata _publicInputs, uint256[] calldata _proof) private pure returns (bool) {
        uint256 foldedPublicInput = _publicInputs.length == 1
            ? _publicInputs[0]
            : uint256(keccak256(abi.encodePacked(_publicInputs)));
        foldedPublicInput = foldedPublicInput >> PUBLIC_INPUT_SHIFT;

        if (_proof[3] != foldedPublicInput) {
            revert InvalidMockProof();
        }
        for (uint256 i = 4; i < ZISK_SNARK_PROOF_LENGTH; ++i) {
            if (_proof[i] != 0) {
                revert InvalidMockProof();
            }
        }

        return true;
    }
}
