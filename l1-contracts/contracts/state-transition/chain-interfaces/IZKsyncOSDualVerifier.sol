// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifierV2} from "./IVerifierV2.sol";
import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for ZKsyncOSDualVerifier sub-verifier getters
interface IZKsyncOSDualVerifier {
    function fflonkVerifiers(uint32 version) external view returns (IVerifierV2);
    function plonkVerifiers(uint32 version) external view returns (IVerifier);
}
