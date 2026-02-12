// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for ZKsyncOSDualVerifier sub-verifier getters
interface IZKsyncOSDualVerifier {
    function plonkVerifiers(uint32 version) external view returns (IVerifier);
}
