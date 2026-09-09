// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifier} from "./IVerifier.sol";

/// @title Era multi-proof verifier interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The policy a chain's installed verifier answers for itself: which proof systems it can
/// check, which of them a batch must satisfy under a given disable mask, and the proof encoding it
/// accepts. A chain reads its policy from here rather than deriving it, so the verifier stays the
/// single place that knows what it enforces.
///
/// @dev Three questions, because in Era one does not answer the others. The accepted encoding is
/// `ERA_MULTI_PROOF_TYPE` whatever the mask says, so unlike the ZKsync OS lane — where the mask
/// selects the proof type and a single `getProofMode` can stand for the policy — the type here
/// describes none of it. `supportedProofSystems` is a property of the deployed gate and never
/// changes; `requiredProofSystems` is what a mask leaves standing on top of it.
///
/// @dev The bits are the `*_PROOF_SYSTEM_DISABLED` values from `Config.sol`, naming a system here
/// rather than disabling one. They identify the same systems in either direction.
interface IEraMultiProofVerifier {
    /// @return The Airbender lane's verifier.
    // solhint-disable-next-line func-name-mixedcase
    function AIRBENDER_VERIFIER() external view returns (IVerifier);

    /// @notice The proof systems this verifier has a lane for.
    /// @dev Fixed at deployment, since the lanes are immutable. This is the capability question: a
    /// chain asks it to find out whether the verifier it has installed can enforce the policy it is
    /// about to declare, instead of testing which getters happen to answer.
    /// @return Bit mask of supported systems.
    function supportedProofSystems() external view returns (uint8);

    /// @notice The proof systems a batch must be proved against under `_disabledProofSystems`.
    /// @dev Reverts on a mask this verifier would refuse at settlement, so a caller is never told a
    /// policy the gate will not honour.
    /// @param _disabledProofSystems The calling chain's disable mask.
    /// @return Bit mask of the systems that must verify.
    function requiredProofSystems(uint8 _disabledProofSystems) external view returns (uint8);

    /// @notice The proof envelope type this verifier accepts in `_proof[0]`.
    function acceptedProofType() external view returns (uint256);
}
