// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for the ZKsync OS verifier getter.
interface IZKsyncOSVerifier {
    function PLONK_VERIFIER() external view returns (IVerifier);
}
