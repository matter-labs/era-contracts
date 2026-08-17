// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraDualVerifier} from "./EraDualVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IEraDualVerifier} from "../chain-interfaces/IEraDualVerifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to skip the zkp verification for the testnet environment.
/// If the proof is not empty, it will verify it using the main verifier contract,
/// otherwise, it will skip the verification.
contract EraTestnetVerifier is IVerifier, IEraDualVerifier {
    EraDualVerifier public immutable DUAL_VERIFIER;
    bool public constant IS_TESTNET_VERIFIER = true;

    constructor(IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier, IVerifier _airbenderPlonkVerifier) {
        assert(block.chainid != 1);

        DUAL_VERIFIER = new EraDualVerifier(_fflonkVerifier, _plonkVerifier, _airbenderPlonkVerifier);
    }

    /// @dev Verifies a zk-SNARK proof, skipping the verification if the proof is empty.
    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view override returns (bool) {
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.length == 0) {
            return true;
        }

        // Forward `msg.sender` (the chain's diamond) explicitly: calling `DUAL_VERIFIER.verify`
        // would make this wrapper the chain as far as the proof-system policy is concerned.
        return DUAL_VERIFIER.verifyForChain(msg.sender, _publicInputs, _proof);
    }

    /// @inheritdoc IEraDualVerifier
    /// @dev Keeps the empty-proof skip so a testnet chain's policy cannot make proof-less
    /// verification start failing.
    function verifyForChain(
        address _chain,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) external view override returns (bool) {
        if (_proof.length == 0) {
            return true;
        }

        return DUAL_VERIFIER.verifyForChain(_chain, _publicInputs, _proof);
    }

    /// @inheritdoc IEraDualVerifier
    function enabledProofSystems(address _chain) external view override returns (uint8) {
        return DUAL_VERIFIER.enabledProofSystems(_chain);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return DUAL_VERIFIER.verificationKeyHash();
    }

    /// @inheritdoc IEraDualVerifier
    // solhint-disable-next-line func-name-mixedcase
    function FFLONK_VERIFIER() external view override returns (IVerifierV2) {
        return DUAL_VERIFIER.FFLONK_VERIFIER();
    }

    /// @inheritdoc IEraDualVerifier
    // solhint-disable-next-line func-name-mixedcase
    function PLONK_VERIFIER() external view override returns (IVerifier) {
        return DUAL_VERIFIER.PLONK_VERIFIER();
    }

    /// @inheritdoc IEraDualVerifier
    // solhint-disable-next-line func-name-mixedcase
    function AIRBENDER_PLONK_VERIFIER() external view override returns (IVerifier) {
        return DUAL_VERIFIER.AIRBENDER_PLONK_VERIFIER();
    }
}
