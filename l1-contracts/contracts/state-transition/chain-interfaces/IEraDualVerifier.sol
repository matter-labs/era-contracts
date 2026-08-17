// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IVerifierV2} from "./IVerifierV2.sol";
import {IVerifier} from "./IVerifier.sol";

/// @dev Policy bit for the Boojum proof system, covering both of its wrappers (FFLONK, proof type 0,
/// and PLONK, proof type 1). Boojum is a single switch because the FFLONK/PLONK split is a wrapper
/// detail rather than a different prover.
uint8 constant BOOJUM_PROOF_SYSTEM = 1;

/// @dev Policy bit for the Airbender proof system (proof type 2).
uint8 constant AIRBENDER_PROOF_SYSTEM = 2;

/// @dev Every known policy bit. Masks above this set bits with no meaning.
/// @dev Declared at file level so the verifier, the calldata-generating scripts and the tests all
/// read the same value instead of each hardcoding `3`.
uint8 constant ALL_PROOF_SYSTEMS = BOOJUM_PROOF_SYSTEM | AIRBENDER_PROOF_SYSTEM;

/// @dev The policy applied to a chain that never set one: Boojum on, Airbender off. Airbender is
/// opt-in, so an unconfigured chain keeps settling exactly as it did before the Airbender slot
/// existed.
uint8 constant DEFAULT_PROOF_SYSTEMS = BOOJUM_PROOF_SYSTEM;

/// @notice Interface for EraDualVerifier sub-verifier getters and the per-chain proof-system policy.
interface IEraDualVerifier {
    /// @notice Emitted when a chain's enabled proof systems change.
    /// @param chain The ZK chain whose policy changed.
    /// @param oldEnabledProofSystems The previous effective mask.
    /// @param newEnabledProofSystems The new mask.
    event EnabledProofSystemsUpdated(address indexed chain, uint8 oldEnabledProofSystems, uint8 newEnabledProofSystems);

    // solhint-disable-next-line func-name-mixedcase
    function FFLONK_VERIFIER() external view returns (IVerifierV2);

    // solhint-disable-next-line func-name-mixedcase
    function PLONK_VERIFIER() external view returns (IVerifier);

    // solhint-disable-next-line func-name-mixedcase
    function AIRBENDER_PLONK_VERIFIER() external view returns (IVerifier);

    /// @notice The proof systems `_chain` currently accepts, as a bit mask.
    /// @dev Bit 0 (`1`) is Boojum (both the FFLONK and PLONK wrappers), bit 1 (`2`) is Airbender.
    /// A chain that never set a policy reads as Boojum-only.
    /// @dev The setter (`EraDualVerifier.setEnabledProofSystems`) is deliberately not part of this
    /// interface: it authorizes against `msg.sender`, so a wrapper cannot forward it. A chain whose
    /// verifier is `EraTestnetVerifier` configures the policy on its `DUAL_VERIFIER()` directly.
    function enabledProofSystems(address _chain) external view returns (uint8);

    /// @notice Verify a proof against `_chain`'s policy, regardless of who is calling.
    /// @dev `verify` uses `msg.sender` as the chain, which is correct when the chain's diamond calls
    /// the dual verifier directly. Wrappers (e.g. the testnet verifier) must use this variant so the
    /// chain identity is not shadowed by the wrapper's own address.
    function verifyForChain(
        address _chain,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) external view returns (bool);
}
