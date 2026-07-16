// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMTransition} from "../upgrades/registry/ICTMTransition.sol";
import {CTMUpgradeComposer} from "../upgrades/registry/CTMUpgradeComposer.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @title RegistryComposerHarness
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Dev-only external view surface over the `CTMUpgradeComposer` library. Off-chain test
///         harnesses (e.g. the anvil registry-driven upgrade runner) deploy this contract to
///         obtain the exact registry-composed L2 protocol upgrade transaction — both to assert
///         the hash committed on a chain diamond and to relay the transaction to an L2 test chain.
/// @dev Never deployed in production. The same composition runs inside `CTMUpgradeExecutor` when a
///      registry-driven upgrade executes; this harness only re-exposes it as external views so
///      TypeScript tooling does not have to replicate the encoding.
contract RegistryComposerHarness {
    /// @notice The L2 protocol upgrade transaction composed from the registry's constants.
    function l2UpgradeTx(ICTMTransition _transition) public view returns (L2CanonicalTransaction memory) {
        return CTMUpgradeComposer.buildL2UpgradeTx(_transition);
    }

    /// @notice keccak256 of the ABI-encoded composed transaction — the exact value that
    ///         `BaseZkSyncUpgrade._setL2SystemContractUpgrade` stores on the chain diamond as
    ///         `l2SystemContractsUpgradeTxHash`.
    function l2UpgradeTxHash(ICTMTransition _transition) external view returns (bytes32) {
        return keccak256(abi.encode(l2UpgradeTx(_transition)));
    }
}
