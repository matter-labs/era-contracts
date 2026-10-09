// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @notice Interface for the ZKsync OS verifier getters.
interface IZKsyncOSVerifier {
    /// @notice Returns the required real proof type for the chain's disable mask.
    /// @param _disabledProofSystems The calling chain's disabled proof systems.
    /// @return The accepted real proof type: 2 for Airbender or 5 for multiprover.
    function getProofMode(uint8 _disabledProofSystems) external view returns (uint256);

    function PLONK_VERIFIER() external view returns (IVerifier);

    /// @notice Whether this is a testnet verifier that supports mock proof verification.
    function isTestnetVerifier() external view returns (bool);
}
