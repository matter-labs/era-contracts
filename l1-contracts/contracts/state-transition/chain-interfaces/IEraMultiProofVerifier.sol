// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @title Era multi-proof verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The proof-system policy a chain's installed verifier reports for itself.
/// @dev Masks use the `*_PROOF_SYSTEM_DISABLED` bits from `Config.sol` to name a system.
interface IEraMultiProofVerifier {
    /// @return The Airbender lane's verifier.
    // solhint-disable-next-line func-name-mixedcase
    function AIRBENDER_VERIFIER() external view returns (IVerifier);

    /// @notice Mask of the proof systems this deployment has a lane for.
    function supportedProofSystems() external view returns (uint8);

    /// @notice Mask of the proof systems a batch must be proved against under `_disabledProofSystems`.
    /// @dev Reverts on a mask settlement would refuse.
    function requiredProofSystems(uint8 _disabledProofSystems) external view returns (uint8);

    /// @notice The proof envelope type accepted in `_proof[0]`.
    function acceptedProofType() external view returns (uint256);
}
