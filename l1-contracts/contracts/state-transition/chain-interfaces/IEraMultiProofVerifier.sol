// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @title Era multi-proof verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The marker a chain checks to know its installed verifier is the multi-proof gate rather
/// than a single-system router. `EraDualVerifier` does not answer this call, so a staticcall that
/// reverts is the negative answer.
interface IEraMultiProofVerifier {
    /// @return The Airbender lane's verifier.
    // solhint-disable-next-line func-name-mixedcase
    function AIRBENDER_VERIFIER() external view returns (IVerifier);
}
