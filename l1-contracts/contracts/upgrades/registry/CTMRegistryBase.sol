// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreContract, CTMContract} from "./ContractIdentifiers.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {RegistryUnknownKey} from "../../common/L1ContractErrors.sol";

/// @title Per-CTM registry logic base.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The FIXED, hand-written half of a generated registry: every `ICTMRegistry` getter's
///         lookup logic, version gating and revert semantics live here, audited once. Generated
///         per-upgrade code only supplies DATA — typed rows returned from the `_*` hooks by a
///         generated library — so the per-upgrade audit diff is data, never logic.
/// @dev Hooks are `internal pure` and their library implementations are inlined at compile time:
///      the deployed registry is still a single constants-in-bytecode contract whose
///      `EXTCODEHASH` commits to every value.
abstract contract CTMRegistryBase is ICTMRegistry {
    /// @dev One `(contract, version) -> address` entry for NON-FACET contracts (DefaultUpgrade,
    ///      DiamondInit, ...), pinned for the new version only; facet addresses live in the facet
    ///      rows. Old-version data is deliberately not recorded — the upgrade only needs the new
    ///      addresses.
    struct AddressRow {
        CTMContract key;
        uint256 protocolVersion;
        address value;
    }

    /// @dev One facet row. NEW-version rows are the complete post-upgrade facet set, each with
    ///      its address. OLD-version rows are the upgrade PLAN — only the facets this upgrade
    ///      touches: a changed facet carries its old address, a facet being added carries a zero
    ///      address, and a facet being removed appears on the old side only. Facets unchanged by
    ///      the upgrade have NO old row.
    ///      An empty `selectorList` means "read the facet's own `ISelfDescribingFacet.selectors()`"
    ///      downstream (see `CTMUpgradeComposer`).
    struct FacetRow {
        CTMContract facet;
        uint256 protocolVersion;
        address facetAddress;
        bytes4[] selectorList;
    }

    /// @dev One `version -> verifier` entry (pinned for the new version only).
    struct VerifierRow {
        uint256 protocolVersion;
        address verifier;
    }

    /// @dev Version-independent facet freezability.
    struct FreezabilityRow {
        CTMContract facet;
        bool isFreezable;
    }

    /// @dev One force-deployed core L2 contract of the new version's upgrade transaction.
    struct L2DeploymentRow {
        CoreContract key;
        IComplexUpgrader.UniversalContractUpgradeInfo info;
        bytes32 bytecodeHash;
    }

    /// @dev One `address -> expected EXTCODEHASH` pin for `verifyAll`.
    struct CodehashPin {
        address target;
        bytes32 expectedCodehash;
    }

    /*//////////////////////////////////////////////////////////////
                        GENERATED DATA HOOKS
    //////////////////////////////////////////////////////////////*/

    function _isZKsyncOS() internal pure virtual returns (bool);

    function _oldProtocolVersion() internal pure virtual returns (uint256);

    function _newProtocolVersion() internal pure virtual returns (uint256);

    function _ctmProxy() internal pure virtual returns (address);

    function _ctmAddressRows() internal pure virtual returns (AddressRow[] memory);

    function _verifierRows() internal pure virtual returns (VerifierRow[] memory);

    function _facetRows() internal pure virtual returns (FacetRow[] memory);

    function _freezabilityRows() internal pure virtual returns (FreezabilityRow[] memory);

    function _l2DeploymentRows() internal pure virtual returns (L2DeploymentRow[] memory);

    function _l2UpgradeDelegate() internal pure virtual returns (address delegateTo, bytes memory delegateCalldata);

    function _factoryDepHashes() internal pure virtual returns (uint256[] memory);

    function _baseSystemContractHashes()
        internal
        pure
        virtual
        returns (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash);

    function _fixedForceDeploymentsData() internal pure virtual returns (bytes memory);

    function _chainCreationInitCalldata() internal pure virtual returns (bytes memory);

    function _genesisParams()
        internal
        pure
        virtual
        returns (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        );

    function _codehashPins() internal pure virtual returns (CodehashPin[] memory);

    /*//////////////////////////////////////////////////////////////
                        ICTMRegistry (fixed logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICTMRegistry
    function isZKsyncOS() external pure returns (bool) {
        return _isZKsyncOS();
    }

    /// @inheritdoc ICTMRegistry
    function oldProtocolVersion() external pure returns (uint256) {
        return _oldProtocolVersion();
    }

    /// @inheritdoc ICTMRegistry
    function newProtocolVersion() external pure returns (uint256) {
        return _newProtocolVersion();
    }

    /// @inheritdoc ICTMRegistry
    function ctmProxy() external pure returns (address) {
        return _ctmProxy();
    }

    /// @inheritdoc ICTMRegistry
    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external pure returns (address) {
        _requireKnownVersion(_protocolVersion);
        // Facet addresses resolve from the facet rows (see `FacetRow`); everything else from the
        // address rows.
        FacetRow[] memory facetRows = _facetRows();
        uint256 facetRowsLength = facetRows.length;
        for (uint256 i = 0; i < facetRowsLength; ++i) {
            if (facetRows[i].facet == _contract && facetRows[i].protocolVersion == _protocolVersion) {
                return facetRows[i].facetAddress;
            }
        }
        AddressRow[] memory rows = _ctmAddressRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].key == _contract && rows[i].protocolVersion == _protocolVersion) {
                return rows[i].value;
            }
        }
        // Known version, unpinned contract: does not exist at that version.
        return address(0);
    }

    /// @inheritdoc ICTMRegistry
    function verifier(uint256 _protocolVersion) external pure returns (address) {
        VerifierRow[] memory rows = _verifierRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].protocolVersion == _protocolVersion) {
                return rows[i].verifier;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function facetList(uint256 _protocolVersion) external pure returns (CTMContract[] memory list) {
        _requireKnownVersion(_protocolVersion);
        FacetRow[] memory rows = _facetRows();
        uint256 rowsLength = rows.length;
        uint256 count = 0;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].protocolVersion == _protocolVersion) {
                ++count;
            }
        }
        list = new CTMContract[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].protocolVersion == _protocolVersion) {
                list[index] = rows[i].facet;
                ++index;
            }
        }
    }

    /// @inheritdoc ICTMRegistry
    function facetSelectors(CTMContract _facet, uint256 _protocolVersion) external pure returns (bytes4[] memory) {
        FacetRow[] memory rows = _facetRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].facet == _facet && rows[i].protocolVersion == _protocolVersion) {
                return rows[i].selectorList;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function facetIsFreezable(CTMContract _facet) external pure returns (bool) {
        FreezabilityRow[] memory rows = _freezabilityRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].facet == _facet) {
                return rows[i].isFreezable;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function l2ForceDeployList(uint256 _protocolVersion) external pure returns (CoreContract[] memory list) {
        _requireNewVersion(_protocolVersion);
        L2DeploymentRow[] memory rows = _l2DeploymentRows();
        uint256 rowsLength = rows.length;
        list = new CoreContract[](rowsLength);
        for (uint256 i = 0; i < rowsLength; ++i) {
            list[i] = rows[i].key;
        }
    }

    /// @inheritdoc ICTMRegistry
    function l2ForceDeployment(
        CoreContract _contract,
        uint256 _protocolVersion
    ) external pure returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        _requireNewVersion(_protocolVersion);
        L2DeploymentRow[] memory rows = _l2DeploymentRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].key == _contract) {
                return rows[i].info;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function l2BytecodeHash(CoreContract _contract, uint256 _protocolVersion) external pure returns (bytes32) {
        _requireKnownVersion(_protocolVersion);
        L2DeploymentRow[] memory rows = _l2DeploymentRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].key == _contract && _protocolVersion == _newProtocolVersion()) {
                return rows[i].bytecodeHash;
            }
        }
        // Known version, contract not force-deployed at it.
        return bytes32(0);
    }

    /// @inheritdoc ICTMRegistry
    function l2UpgradeDelegate(
        uint256 _protocolVersion
    ) external pure returns (address delegateTo, bytes memory delegateCalldata) {
        _requireNewVersion(_protocolVersion);
        return _l2UpgradeDelegate();
    }

    /// @inheritdoc ICTMRegistry
    function factoryDepHashes(uint256 _protocolVersion) external pure returns (uint256[] memory) {
        _requireNewVersion(_protocolVersion);
        return _factoryDepHashes();
    }

    /// @inheritdoc ICTMRegistry
    function baseSystemContractHashes(
        uint256 _protocolVersion
    ) external pure returns (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) {
        _requireNewVersion(_protocolVersion);
        return _baseSystemContractHashes();
    }

    /// @inheritdoc ICTMRegistry
    function fixedForceDeploymentsData(uint256 _protocolVersion) external pure returns (bytes memory) {
        _requireNewVersion(_protocolVersion);
        return _fixedForceDeploymentsData();
    }

    /// @inheritdoc ICTMRegistry
    function chainCreationInitCalldata(uint256 _protocolVersion) external pure returns (bytes memory) {
        _requireNewVersion(_protocolVersion);
        return _chainCreationInitCalldata();
    }

    /// @inheritdoc ICTMRegistry
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
        )
    {
        _requireNewVersion(_protocolVersion);
        return _genesisParams();
    }

    /// @inheritdoc ICTMRegistry
    function verifyAll() external view returns (bool) {
        CodehashPin[] memory pins = _codehashPins();
        uint256 pinsLength = pins.length;
        for (uint256 i = 0; i < pinsLength; ++i) {
            if (pins[i].target.codehash != pins[i].expectedCodehash) {
                return false;
            }
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              internal
    //////////////////////////////////////////////////////////////*/

    function _requireKnownVersion(uint256 _protocolVersion) internal pure {
        if (_protocolVersion != _oldProtocolVersion() && _protocolVersion != _newProtocolVersion()) {
            revert RegistryUnknownKey();
        }
    }

    function _requireNewVersion(uint256 _protocolVersion) internal pure {
        if (_protocolVersion != _newProtocolVersion()) {
            revert RegistryUnknownKey();
        }
    }
}
