// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "../../upgrades/registry/ContractIdentifiers.sol";
import {IGenesisFacetRegistry} from "../../upgrades/registry/IGenesisFacetRegistry.sol";
import {
    RegistryUnknownKey,
    RegistryAlreadyInitialized,
    RegistryLengthMismatch
} from "../../common/L1ContractErrors.sol";

/// @title GenesisRegistry
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The storage-backed genesis registry a freshly deployed ChainTypeManager points at:
///         `DiamondInit` installs a new chain's facet set from here (via `RegistryFacetReader`)
///         and reads the base system contract hashes chains start from — the committed genesis
///         cut carries no facet addresses and no init payload, only a pointer to this registry.
/// @dev Storage-backed rather than constants-in-bytecode (the generated upgrade-registry form)
///      because the pinned values are only known at deploy time: the facet addresses are computed
///      by the deploy flow itself. Used by both the L1 CTM deploy scripts and the on-chain
///      `GatewayCTMDeployer` — the latter runs under zksync-os, so no constructor / immutable is
///      available; deployment is CREATE2 (deterministic address, independent of the pinned
///      values) followed by a one-shot {initialize} in the same flow. The atomic
///      deploy-and-initialize is the commitment (the deployer bytecode + config is what
///      governance approves), so a one-shot flag is sufficient guarding. Once a protocol upgrade
///      is applied, the CTM's pointer moves to the audited constants-in-bytecode registry of
///      that version.
/// @dev Selectors are pinned empty on purpose: `DiamondInit` reads each facet's own
///      `ISelfDescribingFacet.selectors()` at genesis (the facets are already deployed by then),
///      matching the steady-state registry-driven path.
contract GenesisRegistry is IGenesisFacetRegistry {
    /// @notice The packed SemVer protocol version chains are created at. Also doubles as the
    ///         initialization guard: zero until {initialize} runs, non-zero afterwards.
    uint256 public newProtocolVersion;

    /// @dev The ordered facet set installed in every chain diamond at `newProtocolVersion`.
    CTMContract[] internal facets;

    /// @dev Facet identifier => deployed facet address.
    mapping(CTMContract facet => address facetAddress) internal facetAddressOf;

    /// @dev Facet identifier => whether its selectors are freezable in the diamond.
    mapping(CTMContract facet => bool isFreezable) internal facetIsFreezableOf;

    /// @dev The base system contract hashes chains start from (all zero on ZKsync OS).
    bytes32 internal l2BootloaderBytecodeHash;
    bytes32 internal l2DefaultAccountBytecodeHash;
    bytes32 internal l2EvmEmulatorBytecodeHash;

    /// @notice Pins the genesis data for `_protocolVersion`. Callable exactly once.
    /// @param _protocolVersion The packed SemVer protocol version new chains are created at.
    /// @param _facets The ordered facet set installed at genesis.
    /// @param _addresses The deployed address of each facet, in the same order as `_facets`.
    /// @param _freezable Whether each facet's selectors are freezable, in the same order.
    /// @param _bootloaderHash The hash of the bootloader L2 bytecode (zero on ZKsync OS).
    /// @param _defaultAccountHash The hash of the default account L2 bytecode (zero on ZKsync OS).
    /// @param _evmEmulatorHash The hash of the EVM emulator L2 bytecode (zero on ZKsync OS).
    function initialize(
        uint256 _protocolVersion,
        CTMContract[] calldata _facets,
        address[] calldata _addresses,
        bool[] calldata _freezable,
        bytes32 _bootloaderHash,
        bytes32 _defaultAccountHash,
        bytes32 _evmEmulatorHash
    ) external {
        if (newProtocolVersion != 0) {
            revert RegistryAlreadyInitialized();
        }
        uint256 facetsLength = _facets.length;
        if (_addresses.length != facetsLength || _freezable.length != facetsLength) {
            revert RegistryLengthMismatch();
        }

        newProtocolVersion = _protocolVersion;
        for (uint256 i = 0; i < facetsLength; ++i) {
            CTMContract facet = _facets[i];
            facets.push(facet);
            facetAddressOf[facet] = _addresses[i];
            facetIsFreezableOf[facet] = _freezable[i];
        }

        l2BootloaderBytecodeHash = _bootloaderHash;
        l2DefaultAccountBytecodeHash = _defaultAccountHash;
        l2EvmEmulatorBytecodeHash = _evmEmulatorHash;
    }

    /// @inheritdoc IGenesisFacetRegistry
    function facetList(uint256 _protocolVersion) external view returns (CTMContract[] memory) {
        _checkVersion(_protocolVersion);
        return facets;
    }

    /// @inheritdoc IGenesisFacetRegistry
    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external view returns (address) {
        _checkVersion(_protocolVersion);
        return facetAddressOf[_contract];
    }

    /// @inheritdoc IGenesisFacetRegistry
    /// @dev Always empty: `DiamondInit` resolves selectors from each facet's own bytecode.
    function facetSelectors(CTMContract, uint256 _protocolVersion) external view returns (bytes4[] memory) {
        _checkVersion(_protocolVersion);
        return new bytes4[](0);
    }

    /// @inheritdoc IGenesisFacetRegistry
    function facetIsFreezable(CTMContract _facet) external view returns (bool) {
        return facetIsFreezableOf[_facet];
    }

    /// @inheritdoc IGenesisFacetRegistry
    function baseSystemContractHashes(
        uint256 _protocolVersion
    ) external view returns (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) {
        _checkVersion(_protocolVersion);
        return (l2BootloaderBytecodeHash, l2DefaultAccountBytecodeHash, l2EvmEmulatorBytecodeHash);
    }

    /// @dev Only the single pinned protocol version is answerable, mirroring the generated
    ///      registries' `RegistryUnknownKey` semantics.
    function _checkVersion(uint256 _protocolVersion) internal view {
        if (_protocolVersion != newProtocolVersion || newProtocolVersion == 0) {
            revert RegistryUnknownKey();
        }
    }
}
