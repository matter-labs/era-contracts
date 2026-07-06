// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {CoreContract, CTMContract, ZKsyncOSUpgradeType} from "./ContractIdentifiers.sol";

/// @title Per-CTM upgrade registry (one per ChainTypeManager: Era and ZKsyncOS).
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a generated, constants-in-bytecode registry that pins every
///         CTM-scoped value for one protocol upgrade: facet addresses and selector lists,
///         verifier addresses, L2 system-contract bytecode hashes and genesis parameters.
/// @dev See `ICoreRegistry` for the constants-in-bytecode model. The upgrade orchestrator reads
///      this registry to compose diamond cuts, `ChainCreationParams` and the L2 protocol upgrade
///      transaction on-chain; nothing here is ever passed as hand-built calldata.
/// @dev Getters revert for unknown `(contract, version)` combinations.
interface ICTMRegistry {
    /// @notice The packed SemVer (see `SemVer.sol`) protocol version this registry upgrades from.
    function oldProtocolVersion() external pure returns (uint256);

    /// @notice The packed SemVer protocol version this registry upgrades to.
    function newProtocolVersion() external pure returns (uint256);

    /// @notice Address of a CTM-scoped contract (facet, verifier, ValidatorTimelock, CTM
    ///         implementation, ...) at a given protocol version.
    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external pure returns (address);

    /// @notice The function selectors a facet registers in the diamond at a given protocol version.
    /// @dev Generated from the audited facet source (`forge inspect <Facet> methodIdentifiers`).
    ///      Together with `ctmAddress`, this lets the orchestrator diff the old and new facet sets
    ///      without reading live diamond state.
    function facetSelectors(CTMContract _facet, uint256 _protocolVersion) external pure returns (bytes4[] memory);

    /// @notice Whether the facet's selectors are freezable in the diamond.
    function facetIsFreezable(CTMContract _facet) external pure returns (bool);

    /// @notice The pinned L2 bytecode hash of a core L2 contract at a given protocol version.
    /// @dev Era registries pin EraVM (versioned) bytecode hashes; ZKsyncOS registries pin
    ///      ZKsyncOS bytecode hashes. Returns zero for contracts that are not force-deployed
    ///      on this CTM at this version.
    function l2BytecodeHash(CoreContract _contract, uint256 _protocolVersion) external pure returns (bytes32);

    /// @notice How a core L2 contract is deployed during a ZKsyncOS upgrade.
    /// @dev Only meaningful on the ZKsyncOS registry; mirrors
    ///      `ComplexUpgrader.UniversalContractUpgradeInfo.upgradeType` composition.
    function l2UpgradeType(CoreContract _contract) external pure returns (ZKsyncOSUpgradeType);

    /// @notice Genesis VM-state values for a given protocol version. These are outputs of running
    ///         the genesis VM off-chain with the pinned L2 system-contract set; the audit step is
    ///         reproducing that run.
    function genesisParams(
        uint256 _protocolVersion
    )
        external
        pure
        returns (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        );
}
