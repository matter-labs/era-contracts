// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for the ZKsync OS verifier getters.
interface IZKsyncOSVerifier {
    function PLONK_VERIFIER() external view returns (IVerifier);

    /// @notice Whether this is a testnet verifier that supports mock proof verification.
    function IS_TESTNET_VERIFIER() external view returns (bool);
}
