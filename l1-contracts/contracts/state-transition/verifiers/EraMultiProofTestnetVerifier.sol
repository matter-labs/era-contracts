// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraMultiProofVerifier} from "./EraMultiProofVerifier.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {MAINNET_CHAIN_ID} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Testnet variant of the Era dual-prover gate: an empty proof skips verification.
/// @dev Inherits `EraMultiProofVerifier` rather than wrapping it. A wrapper would stand between the chain
/// and the production contract, becoming the `msg.sender` that `disabledProofSystems` is read from, which is
/// why the ZKsync OS lane's wrapped testnet verifier has to answer a hardcoded value instead. Inheriting
/// keeps the chain's diamond as the caller, so a testnet chain exercises the same code path as mainnet.
contract EraMultiProofTestnetVerifier is EraMultiProofVerifier {
    bool public constant IS_TESTNET_VERIFIER = true;

    constructor(
        IVerifier _boojumVerifier,
        IVerifier _airbenderVerifier
    ) EraMultiProofVerifier(_boojumVerifier, _airbenderVerifier) {
        assert(block.chainid != MAINNET_CHAIN_ID);
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
