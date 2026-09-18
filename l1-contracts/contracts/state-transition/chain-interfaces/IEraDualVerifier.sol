// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifierV2} from "./IVerifierV2.sol";
import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for EraDualVerifier sub-verifier getters
interface IEraDualVerifier {
    function FFLONK_VERIFIER() external view returns (IVerifierV2);
    function PLONK_VERIFIER() external view returns (IVerifier);

    /// @notice The verification key hash of one sub-verifier, selected by proof type.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32);
}
