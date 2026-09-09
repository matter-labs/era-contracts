// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraMultiProofVerifier} from "./EraMultiProofVerifier.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IEraVerifier} from "../chain-interfaces/IEraVerifier.sol";
import {MAINNET_CHAIN_ID} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Testnet variant of the Era dual-prover gate: an empty proof skips verification.
/// @dev Inherits rather than wraps `EraMultiProofVerifier`: a wrapper would become the `msg.sender` the
/// gate reads `disabledProofSystems` from, taking the mask off the wrapper instead of the chain's diamond.
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
