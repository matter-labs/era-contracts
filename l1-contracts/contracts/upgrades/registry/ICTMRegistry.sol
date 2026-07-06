// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreContract, CTMContract} from "./ContractIdentifiers.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";

/// @title Per-CTM upgrade registry (one per ChainTypeManager: Era and ZKsyncOS).
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a generated, constants-in-bytecode registry that pins every
///         CTM-scoped value for one protocol upgrade: facet addresses and selector lists,
///         verifier addresses, L2 force-deployments, factory dependencies and genesis parameters.
/// @dev See `ICoreRegistry` for the constants-in-bytecode model. The upgrade orchestrator
///      (`RegistryUpgradeModule` + `UpgradeComposer`) reads this registry to compose diamond
///      cuts, `ChainCreationParams` and the L2 protocol upgrade transaction on-chain; nothing
///      is ever passed as hand-built calldata.
/// @dev Getters revert for unknown `(key, version)` combinations; only the two pinned versions
///      (`oldProtocolVersion`, `newProtocolVersion`) are answerable.
interface ICTMRegistry {
    /// @notice Whether this registry describes the ZKsyncOS CTM (true) or the Era one (false).
    function isZKsyncOS() external view returns (bool);

    /// @notice The packed SemVer (see `SemVer.sol`) protocol version this registry upgrades from.
    function oldProtocolVersion() external view returns (uint256);

    /// @notice The packed SemVer protocol version this registry upgrades to.
    function newProtocolVersion() external view returns (uint256);

    /// @notice The ChainTypeManager proxy address (version-independent).
    function ctmProxy() external view returns (address);

    /// @notice Address of a CTM-scoped contract (facet, verifier, upgrade contract, DiamondInit,
    ///         ValidatorTimelock, CTM implementation, ...) at a given protocol version.
    ///         Returns zero for contracts that do not exist at that version.
    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external view returns (address);

    /// @notice The verifier address chains verify against at a given protocol version.
    function verifier(uint256 _protocolVersion) external view returns (address);

    /// @notice The facets installed in every chain diamond at a given protocol version.
    function facetList(uint256 _protocolVersion) external view returns (CTMContract[] memory);

    /// @notice The function selectors a facet registers in the diamond at a given protocol version.
    /// @dev Generated from the audited facet source (`forge inspect <Facet> methodIdentifiers`).
    ///      Together with `ctmAddress`, this lets the orchestrator diff the old and new facet sets
    ///      without reading live diamond state (uniform facet sets per protocol version).
    function facetSelectors(CTMContract _facet, uint256 _protocolVersion) external view returns (bytes4[] memory);

    /// @notice Whether the facet's selectors are freezable in the diamond.
    function facetIsFreezable(CTMContract _facet) external view returns (bool);

    /// @notice The core L2 contracts force-deployed by the upgrade transaction of a given
    ///         protocol version, in deployment order (the L2 registry, if any, goes first).
    function l2ForceDeployList(uint256 _protocolVersion) external view returns (CoreContract[] memory);

    /// @notice The complete universal force-deployment descriptor of a core L2 contract at a
    ///         given protocol version: upgrade type (Era force deployment / ZKsyncOS system-proxy
    ///         or unsafe), VM-specific `deployedBytecodeInfo` encoding, and the target address.
    function l2ForceDeployment(
        CoreContract _contract,
        uint256 _protocolVersion
    ) external view returns (IComplexUpgrader.UniversalContractUpgradeInfo memory);

    /// @notice The pinned L2 bytecode hash of a core L2 contract at a given protocol version.
    ///         Returns zero for contracts that are not deployed on this CTM at this version.
    function l2BytecodeHash(CoreContract _contract, uint256 _protocolVersion) external view returns (bytes32);

    /// @notice The delegate target and calldata the L2 `ComplexUpgrader` delegate-calls after the
    ///         force deployments (the version-specific L2 upgrade implementation and its
    ///         ecosystem-wide arguments; per-chain data is filled in downstream where needed).
    function l2UpgradeDelegate(
        uint256 _protocolVersion
    ) external view returns (address delegateTo, bytes memory delegateCalldata);

    /// @notice The full ordered factory-dependency hash list of the upgrade transaction at a
    ///         given protocol version. All hashes must be published to the `BytecodesSupplier`
    ///         before the upgrade executes.
    function factoryDepHashes(uint256 _protocolVersion) external view returns (uint256[] memory);

    /// @notice The base system contract hashes at a given protocol version. Zero means
    ///         "not updated by this upgrade" (see `ProposedUpgrade`).
    function baseSystemContractHashes(
        uint256 _protocolVersion
    ) external view returns (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash);

    /// @notice The encoded ecosystem-wide `FixedForceDeploymentsData` used as
    ///         `ChainCreationParams.forceDeploymentsData` for newly created chains.
    function fixedForceDeploymentsData(uint256 _protocolVersion) external view returns (bytes memory);

    /// @notice The init calldata of the chain-creation diamond cut (the encoded
    ///         `DiamondInit.initialize` payload) at a given protocol version.
    function chainCreationInitCalldata(uint256 _protocolVersion) external view returns (bytes memory);

    /// @notice Genesis VM-state values for a given protocol version. These are outputs of running
    ///         the genesis VM off-chain with the pinned L2 system-contract set; the audit step is
    ///         reproducing that run.
    function genesisParams(
        uint256 _protocolVersion
    )
        external
        view
        returns (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        );

    /// @notice Walks every pinned L1 address and compares its `EXTCODEHASH` against the hash
    ///         pinned at generation time. Anyone can call this to check that the deployed
    ///         bytecode matches what was audited.
    function verifyAll() external view returns (bool);
}
