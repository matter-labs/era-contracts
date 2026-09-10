// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifierV2} from "./IVerifierV2.sol";
import {IVerifier} from "./IVerifier.sol";
import {IEraVerifier} from "./IEraVerifier.sol";

/// @notice Interface for EraDualVerifier sub-verifier getters.
/// @dev Boojum only. The Airbender lane lives behind `AirbenderVerifier`, which owns its own
/// public-input binding and is never reachable through this router.
/// @dev Extends `IEraVerifier` so every Era verifier a chain can install — this router, the
/// multi-proof gate, and both testnet builds — answers the testnet flag.
interface IEraDualVerifier is IEraVerifier {
    function FFLONK_VERIFIER() external view returns (IVerifierV2);
    function PLONK_VERIFIER() external view returns (IVerifier);
}
