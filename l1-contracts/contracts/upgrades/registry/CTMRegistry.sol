// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreContract, CTMContract} from "./ContractIdentifiers.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {RegistryAlreadyInitialized, RegistryUnknownKey} from "../../common/L1ContractErrors.sol";

/// @title Per-CTM registry (one instance per ChainTypeManager per protocol upgrade, plus one
///        bootstrap instance per fresh CTM deployment).
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed and WRITE-ONCE: {initialize} pins the full manifest exactly once and
///         there is no other state-mutating function, so after that single call the values are
///         as immutable as compiled constants. The contract itself is a fixed, audited-once
///         implementation (one well-known codehash for every registry instance); a per-instance
///         review is therefore a pure DATA check — read the getters (or compare {manifestHash})
///         against the audited manifest.
/// @dev No constructor and no immutables: the same bytecode must deploy under zksync-os (the
///      Gateway CTM deployer creates and initializes one atomically). On L1 the deploy script
///      initializes in a follow-up transaction; because anyone could theoretically call
///      {initialize} first, deploy flows MUST verify the contents (e.g. {manifestHash}) before
///      the address is pinned anywhere — a front-run initialization is a griefing that forces a
///      redeploy, never a silently poisoned registry.
/// @dev Getters revert with `RegistryUnknownKey` for unknown `(key, version)` combinations; only
///      the pinned versions are answerable (see `ICTMRegistry`).
contract CTMRegistry is ICTMRegistry {
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

    /// @notice Everything a registry instance pins, set exactly once by {initialize}.
    /// @dev For a BOOTSTRAP (genesis) registry of a freshly deployed CTM most sections are empty:
    ///      only `newProtocolVersion`, the new-version facet rows, freezability rows and the base
    ///      system contract hashes are needed by `DiamondInit`; `oldProtocolVersion` is zero.
    /// @dev Field order mirrors review-friendly manifest grouping; the struct is calldata-only.
    // solhint-disable-next-line gas-struct-packing
    struct CTMRegistryManifest {
        bool isZKsyncOS;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        address ctmProxy;
        AddressRow[] ctmAddressRows;
        VerifierRow[] verifierRows;
        FacetRow[] facetRows;
        FreezabilityRow[] freezabilityRows;
        L2DeploymentRow[] l2DeploymentRows;
        address l2UpgradeDelegateTo;
        bytes l2UpgradeDelegateCalldata;
        uint256[] factoryDepHashes;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        bytes fixedForceDeploymentsData;
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        bytes32 genesisBatchCommitment;
        uint64 genesisIndexRepeatedStorageChanges;
        CodehashPin[] codehashPins;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot guard: false until {initialize} runs, true forever after.
    bool public initialized;

    /// @notice `keccak256(abi.encode(manifest))` of the pinned manifest — a single 32-byte
    ///         commitment to every value this registry serves, quotable in governance proposals
    ///         and comparable against the audited manifest off-chain.
    bytes32 public manifestHash;

    bool internal isZKsyncOS_;
    uint256 internal oldProtocolVersion_;
    uint256 internal newProtocolVersion_;
    address internal ctmProxy_;
    AddressRow[] internal ctmAddressRows;
    VerifierRow[] internal verifierRows;
    FacetRow[] internal facetRows;
    FreezabilityRow[] internal freezabilityRows;
    L2DeploymentRow[] internal l2DeploymentRows;
    address internal l2UpgradeDelegateTo;
    bytes internal l2UpgradeDelegateCalldata;
    uint256[] internal factoryDepHashes_;
    bytes32 internal bootloaderHash;
    bytes32 internal defaultAccountHash;
    bytes32 internal evmEmulatorHash;
    bytes internal fixedForceDeploymentsData_;
    address internal genesisUpgrade;
    bytes32 internal genesisBatchHash;
    bytes32 internal genesisBatchCommitment;
    uint64 internal genesisIndexRepeatedStorageChanges;
    CodehashPin[] internal codehashPins;

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pins the full manifest. Callable exactly once; there is no other state-mutating
    ///         function on this contract.
    /// @param _manifest The manifest to pin.
    function initialize(CTMRegistryManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        // A zero new version would make every version-gated getter unanswerable and break the
        // `RegistryUnknownKey` semantics downstream.
        if (_manifest.newProtocolVersion == 0) {
            revert RegistryUnknownKey();
        }
        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));

        isZKsyncOS_ = _manifest.isZKsyncOS;
        oldProtocolVersion_ = _manifest.oldProtocolVersion;
        newProtocolVersion_ = _manifest.newProtocolVersion;
        ctmProxy_ = _manifest.ctmProxy;
        uint256 length = _manifest.ctmAddressRows.length;
        for (uint256 i = 0; i < length; ++i) {
            ctmAddressRows.push(_manifest.ctmAddressRows[i]);
        }
        length = _manifest.verifierRows.length;
        for (uint256 i = 0; i < length; ++i) {
            verifierRows.push(_manifest.verifierRows[i]);
        }
        length = _manifest.facetRows.length;
        for (uint256 i = 0; i < length; ++i) {
            facetRows.push(_manifest.facetRows[i]);
        }
        length = _manifest.freezabilityRows.length;
        for (uint256 i = 0; i < length; ++i) {
            freezabilityRows.push(_manifest.freezabilityRows[i]);
        }
        length = _manifest.l2DeploymentRows.length;
        for (uint256 i = 0; i < length; ++i) {
            l2DeploymentRows.push(_manifest.l2DeploymentRows[i]);
        }
        l2UpgradeDelegateTo = _manifest.l2UpgradeDelegateTo;
        l2UpgradeDelegateCalldata = _manifest.l2UpgradeDelegateCalldata;
        factoryDepHashes_ = _manifest.factoryDepHashes;
        bootloaderHash = _manifest.bootloaderHash;
        defaultAccountHash = _manifest.defaultAccountHash;
        evmEmulatorHash = _manifest.evmEmulatorHash;
        fixedForceDeploymentsData_ = _manifest.fixedForceDeploymentsData;
        genesisUpgrade = _manifest.genesisUpgrade;
        genesisBatchHash = _manifest.genesisBatchHash;
        genesisBatchCommitment = _manifest.genesisBatchCommitment;
        genesisIndexRepeatedStorageChanges = _manifest.genesisIndexRepeatedStorageChanges;
        length = _manifest.codehashPins.length;
        for (uint256 i = 0; i < length; ++i) {
            codehashPins.push(_manifest.codehashPins[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ICTMRegistry (lookup logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICTMRegistry
    function isZKsyncOS() external view returns (bool) {
        return isZKsyncOS_;
    }

    /// @inheritdoc ICTMRegistry
    function oldProtocolVersion() external view returns (uint256) {
        return oldProtocolVersion_;
    }

    /// @inheritdoc ICTMRegistry
    function newProtocolVersion() external view returns (uint256) {
        return newProtocolVersion_;
    }

    /// @inheritdoc ICTMRegistry
    function ctmProxy() external view returns (address) {
        return ctmProxy_;
    }

    /// @inheritdoc ICTMRegistry
    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external view returns (address) {
        _requireKnownVersion(_protocolVersion);
        // Facet addresses resolve from the facet rows (see `FacetRow`); everything else from the
        // address rows.
        uint256 facetRowsLength = facetRows.length;
        for (uint256 i = 0; i < facetRowsLength; ++i) {
            if (facetRows[i].facet == _contract && facetRows[i].protocolVersion == _protocolVersion) {
                return facetRows[i].facetAddress;
            }
        }
        uint256 rowsLength = ctmAddressRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (ctmAddressRows[i].key == _contract && ctmAddressRows[i].protocolVersion == _protocolVersion) {
                return ctmAddressRows[i].value;
            }
        }
        // Known version, unpinned contract: does not exist at that version.
        return address(0);
    }

    /// @inheritdoc ICTMRegistry
    function verifier(uint256 _protocolVersion) external view returns (address) {
        uint256 rowsLength = verifierRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (verifierRows[i].protocolVersion == _protocolVersion) {
                return verifierRows[i].verifier;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function facetList(uint256 _protocolVersion) external view returns (CTMContract[] memory list) {
        _requireKnownVersion(_protocolVersion);
        uint256 rowsLength = facetRows.length;
        uint256 count = 0;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (facetRows[i].protocolVersion == _protocolVersion) {
                ++count;
            }
        }
        list = new CTMContract[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (facetRows[i].protocolVersion == _protocolVersion) {
                list[index] = facetRows[i].facet;
                ++index;
            }
        }
    }

    /// @inheritdoc ICTMRegistry
    function facetSelectors(CTMContract _facet, uint256 _protocolVersion) external view returns (bytes4[] memory) {
        uint256 rowsLength = facetRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (facetRows[i].facet == _facet && facetRows[i].protocolVersion == _protocolVersion) {
                return facetRows[i].selectorList;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function facetIsFreezable(CTMContract _facet) external view returns (bool) {
        uint256 rowsLength = freezabilityRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (freezabilityRows[i].facet == _facet) {
                return freezabilityRows[i].isFreezable;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function l2ForceDeployList(uint256 _protocolVersion) external view returns (CoreContract[] memory list) {
        _requireNewVersion(_protocolVersion);
        uint256 rowsLength = l2DeploymentRows.length;
        list = new CoreContract[](rowsLength);
        for (uint256 i = 0; i < rowsLength; ++i) {
            list[i] = l2DeploymentRows[i].key;
        }
    }

    /// @inheritdoc ICTMRegistry
    function l2ForceDeployment(
        CoreContract _contract,
        uint256 _protocolVersion
    ) external view returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        _requireNewVersion(_protocolVersion);
        uint256 rowsLength = l2DeploymentRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (l2DeploymentRows[i].key == _contract) {
                return l2DeploymentRows[i].info;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICTMRegistry
    function l2BytecodeHash(CoreContract _contract, uint256 _protocolVersion) external view returns (bytes32) {
        _requireKnownVersion(_protocolVersion);
        uint256 rowsLength = l2DeploymentRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (l2DeploymentRows[i].key == _contract && _protocolVersion == newProtocolVersion_) {
                return l2DeploymentRows[i].bytecodeHash;
            }
        }
        // Known version, contract not force-deployed at it.
        return bytes32(0);
    }

    /// @inheritdoc ICTMRegistry
    function l2UpgradeDelegate(
        uint256 _protocolVersion
    ) external view returns (address delegateTo, bytes memory delegateCalldata) {
        _requireNewVersion(_protocolVersion);
        return (l2UpgradeDelegateTo, l2UpgradeDelegateCalldata);
    }

    /// @inheritdoc ICTMRegistry
    function factoryDepHashes(uint256 _protocolVersion) external view returns (uint256[] memory) {
        _requireNewVersion(_protocolVersion);
        return factoryDepHashes_;
    }

    /// @inheritdoc ICTMRegistry
    function baseSystemContractHashes(uint256 _protocolVersion) external view returns (bytes32, bytes32, bytes32) {
        _requireNewVersion(_protocolVersion);
        return (bootloaderHash, defaultAccountHash, evmEmulatorHash);
    }

    /// @inheritdoc ICTMRegistry
    function fixedForceDeploymentsData(uint256 _protocolVersion) external view returns (bytes memory) {
        _requireNewVersion(_protocolVersion);
        return fixedForceDeploymentsData_;
    }

    /// @inheritdoc ICTMRegistry
    function genesisParams(uint256 _protocolVersion) external view returns (address, bytes32, bytes32, uint64) {
        _requireNewVersion(_protocolVersion);
        return (genesisUpgrade, genesisBatchHash, genesisBatchCommitment, genesisIndexRepeatedStorageChanges);
    }

    /// @inheritdoc ICTMRegistry
    function verifyAll() external view returns (bool) {
        uint256 pinsLength = codehashPins.length;
        for (uint256 i = 0; i < pinsLength; ++i) {
            if (codehashPins[i].target.codehash != codehashPins[i].expectedCodehash) {
                return false;
            }
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              internal
    //////////////////////////////////////////////////////////////*/

    /// @dev Version 0 is never answerable: bootstrap (genesis) manifests pin
    ///      `oldProtocolVersion == 0` as "there is no old version", and an uninitialized registry
    ///      has both versions zero — neither may masquerade as an empty-but-valid data set.
    function _requireKnownVersion(uint256 _protocolVersion) internal view {
        if (
            _protocolVersion == 0 ||
            (_protocolVersion != oldProtocolVersion_ && _protocolVersion != newProtocolVersion_)
        ) {
            revert RegistryUnknownKey();
        }
    }

    function _requireNewVersion(uint256 _protocolVersion) internal view {
        if (_protocolVersion == 0 || _protocolVersion != newProtocolVersion_) {
            revert RegistryUnknownKey();
        }
    }
}
