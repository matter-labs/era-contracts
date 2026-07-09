// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "../../../upgrades/registry/ContractIdentifiers.sol";
import {IGenesisFacetRegistry} from "../../../upgrades/registry/IGenesisFacetRegistry.sol";
import {
    RegistryUnknownKey,
    RegistryAlreadyInitialized,
    RegistryLengthMismatch
} from "../../../common/L1ContractErrors.sol";

/// @title GatewayGenesisRegistry
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The genesis facet registry the Gateway ChainTypeManager points at, so `DiamondInit`
///         installs a new chain's facet set from here (via `RegistryFacetReader`) exactly like on
///         L1 — the committed genesis cut carries no facet addresses, only a pointer to this
///         registry.
/// @dev Storage-backed rather than constants-in-bytecode (the L1 form): the Gateway facet
///      addresses are only known at deploy time (they are CREATE2-computed by
///      `GatewayCTMDeployerHelper`), and this registry runs under zksync-os where no constructor /
///      immutable is available. `GatewayCTMDeployer` deploys it via CREATE2 (so its address is
///      deterministic and independent of the facet addresses — letting the off-chain helper put it
///      in the cut before any facet exists) and calls {initialize} once, in the same transaction,
///      to pin the facet set. The atomic deploy-and-initialize is the commitment (the deployer
///      bytecode + config is what governance approves), so a one-shot flag is sufficient guarding.
/// @dev Selectors are pinned empty on purpose: `DiamondInit` reads each facet's own
///      `ISelfDescribingFacet.selectors()` at genesis (the facets are already deployed by then),
///      matching the steady-state L1 registry-driven path.
contract GatewayGenesisRegistry is IGenesisFacetRegistry {
    /// @notice The packed SemVer protocol version chains are created at. Also doubles as the
    ///         initialization guard: zero until {initialize} runs, non-zero afterwards.
    uint256 public newProtocolVersion;

    /// @dev The ordered facet set installed in every chain diamond at `newProtocolVersion`.
    CTMContract[] internal facets;

    /// @dev Facet identifier => deployed facet address.
    mapping(CTMContract facet => address facetAddress) internal facetAddressOf;

    /// @dev Facet identifier => whether its selectors are freezable in the diamond.
    mapping(CTMContract facet => bool isFreezable) internal facetIsFreezableOf;

    /// @notice Pins the facet set for `_protocolVersion`. Callable exactly once.
    /// @param _protocolVersion The packed SemVer protocol version new chains are created at.
    /// @param _facets The ordered facet set installed at genesis.
    /// @param _addresses The deployed address of each facet, in the same order as `_facets`.
    /// @param _freezable Whether each facet's selectors are freezable, in the same order.
    function initialize(
        uint256 _protocolVersion,
        CTMContract[] calldata _facets,
        address[] calldata _addresses,
        bool[] calldata _freezable
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

    /// @dev Only the single pinned protocol version is answerable, mirroring the generated
    ///      registries' `RegistryUnknownKey` semantics.
    function _checkVersion(uint256 _protocolVersion) internal view {
        if (_protocolVersion != newProtocolVersion || newProtocolVersion == 0) {
            revert RegistryUnknownKey();
        }
    }
}
