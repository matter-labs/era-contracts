// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifierV2} from "./IVerifierV2.sol";
import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for EraDualVerifier sub-verifier getters.
/// @dev Boojum only. The Airbender lane lives behind `AirbenderVerifier`, which owns its own
/// public-input binding and is never reachable through this router.
interface IEraDualVerifier {
    function FFLONK_VERIFIER() external view returns (IVerifierV2);
    function PLONK_VERIFIER() external view returns (IVerifier);
}
