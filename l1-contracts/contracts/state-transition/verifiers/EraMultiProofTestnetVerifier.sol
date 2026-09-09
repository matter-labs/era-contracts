// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraMultiProofVerifier} from "./EraMultiProofVerifier.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IEraVerifier} from "../chain-interfaces/IEraVerifier.sol";
import {MAINNET_CHAIN_ID} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Testnet variant of the Era dual-prover gate: an empty proof skips verification.
/// @dev Inherits `EraMultiProofVerifier` rather than wrapping it. A wrapper would stand between the chain
/// and the production contract, becoming the `msg.sender` that `disabledProofSystems` is read from, so the
/// gate would take the mask off the wrapper rather than off the chain's diamond. Inheriting keeps the
/// diamond as the caller, so a testnet chain exercises the same code path as mainnet.
contract EraMultiProofTestnetVerifier is EraMultiProofVerifier {
    /// @dev Kept alongside `isTestnetVerifier()` for tooling that predates the getter.
    bool public constant IS_TESTNET_VERIFIER = true;

    constructor(
        IVerifier _boojumVerifier,
        IVerifier _airbenderVerifier
    ) EraMultiProofVerifier(_boojumVerifier, _airbenderVerifier) {
        assert(block.chainid != MAINNET_CHAIN_ID);
    }

    /// @inheritdoc IEraVerifier
    function isTestnetVerifier() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IVerifier
    /// @dev Skips verification for an empty proof; everything else takes the production path unchanged.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view override returns (bool) {
        if (_proof.length == 0) {
            return true;
        }

        return super.verify(_publicInputs, _proof);
    }
}
