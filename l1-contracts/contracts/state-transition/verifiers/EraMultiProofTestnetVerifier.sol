// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraMultiProofVerifier} from "./EraMultiProofVerifier.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IEraMultiProofVerifier} from "../chain-interfaces/IEraMultiProofVerifier.sol";
import {MAINNET_CHAIN_ID} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Testnet variant of `EraMultiProofVerifier`: an empty proof skips verification.
/// @dev Inherits rather than wraps, so `msg.sender` in `verify` stays the chain whose policy is read.
contract EraMultiProofTestnetVerifier is EraMultiProofVerifier {
    constructor(
        IVerifier _boojumVerifier,
        IVerifier _airbenderVerifier
    ) EraMultiProofVerifier(_boojumVerifier, _airbenderVerifier) {
        assert(block.chainid != MAINNET_CHAIN_ID);
    }

    /// @inheritdoc IEraMultiProofVerifier
    // solhint-disable-next-line func-name-mixedcase
    function IS_TESTNET_VERIFIER() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view override returns (bool) {
        if (_proof.length == 0) {
            return true;
        }

        return super.verify(_publicInputs, _proof);
    }
}
