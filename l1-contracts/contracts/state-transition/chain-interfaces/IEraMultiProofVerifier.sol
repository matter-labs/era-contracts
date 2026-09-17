// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @title Era multi-proof verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Masks use the `*_PROOF_SYSTEM_MASK` bits from `Config.sol`.
interface IEraMultiProofVerifier {
    /// @return The Airbender verifier.
    // solhint-disable-next-line func-name-mixedcase
    function AIRBENDER_VERIFIER() external view returns (IVerifier);

    /// @notice Mask of the proof systems this deployment has a verifier for.
    function supportedProofSystems() external view returns (uint8);

    /// @notice Mask of the proof systems a batch must be proved against under `_disabledProofSystems`.
    /// @dev Reverts if that would leave no proof system.
    function requiredProofSystems(uint8 _disabledProofSystems) external view returns (uint8);

    /// @notice The proof type accepted in `_proof[0]`.
    function acceptedProofType() external view returns (uint256);
}
